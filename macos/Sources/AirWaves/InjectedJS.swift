import Foundation

// ============================================================================
//  注入到页面的 JavaScript（以 Swift 字符串常量承载）
//
//  为什么放在 Swift 源码里而不是独立的 .js 资源文件：
//    WKUserScript 需要的是字符串。若放成资源文件，就要处理
//    「资源没被正确复制进 App 包」这一额外的失败模式，
//    而本工程的注入脚本本身很短、只在编译期变化。
//    用字符串常量可以保证「编译通过 = 脚本一定在包里」。
//
//  设计原则：
//    * 只通过 DOM 事件驱动，不依赖 app.js 暴露任何 API
//      （app.js 是纯 IIFE，没有导出；这条约束无法绕过）
//    * 不修改原仓库任何文件
//    * 在普通浏览器里打开页面时自动降级（不报错、不干扰原功能）
// ============================================================================

enum InjectedJS {

    // ========================================================================
    //  1) 原生偏好桥（documentStart）
    //
    //  存储策略：原生 UserDefaults 是唯一真相。
    //  原因：WKWebView 在自定义 URL scheme 下的 localStorage 持久性
    //  在不同系统版本上表现不一致，而「重启后设置还在」是硬要求。
    //  没有原生桥时（例如用浏览器直开）自动降级到 localStorage，
    //  保证同一份脚本在两种环境下都能工作。
    // ========================================================================

    static let prefsBridge = """
    (function () {
      'use strict';

      var NS = '__airwavesPrefsBridge';
      if (window[NS]) { return; }

      var config = window.__AIRWAVES_NATIVE__ || null;
      var LS_KEY = 'airwaves.prefs.v1';
      var counter = 0;

      // 浏览器环境（无原生桥）下的降级实现
      function readLocal() {
        try {
          var raw = window.localStorage.getItem(LS_KEY);
          return raw ? JSON.parse(raw) : {};
        } catch (e) { return {}; }
      }
      function writeLocal(patch) {
        try {
          var merged = readLocal();
          for (var k in patch) {
            if (Object.prototype.hasOwnProperty.call(patch, k)) { merged[k] = patch[k]; }
          }
          window.localStorage.setItem(LS_KEY, JSON.stringify(merged));
        } catch (e) { /* 隐私模式等场景静默忽略 */ }
      }

      function nativeAvailable() {
        try {
          return !!(window.webkit &&
                    window.webkit.messageHandlers &&
                    window.webkit.messageHandlers.airwavesPrefs);
        } catch (e) { return false; }
      }

      window[NS] = {
        native: nativeAvailable(),

        // 启动时的配置快照；原生不可用时读 localStorage
        read: function () {
          if (config) { return config; }
          var local = readLocal();
          var out = {};
          for (var k in local) {
            if (Object.prototype.hasOwnProperty.call(local, k)) { out[k] = local[k]; }
          }
          out.native = false;
          return out;
        },

        // 只上报发生变化的键，避免前端的部分状态覆盖原生的完整状态
        write: function (patch) {
          if (!patch) { return; }
          if (nativeAvailable()) {
            try {
              // 递增序号方便在日志里分辨先后顺序
              patch.__seq = ++counter;
              window.webkit.messageHandlers.airwavesPrefs.postMessage({ patch: patch });
              return;
            } catch (e) { /* 落到下面走 localStorage */ }
          }
          writeLocal(patch);
        },

        reset: function () {
          if (nativeAvailable()) {
            try {
              window.webkit.messageHandlers.airwavesPrefs.postMessage({ action: 'reset' });
              return;
            } catch (e) { /* 继续走 localStorage */ }
          }
          try { window.localStorage.removeItem(LS_KEY); } catch (e) {}
        },

        // 页面 → 原生 的通知通道（用于把 console 与音频状态写进日志文件）
        notify: function (kind, text, level) {
          if (!nativeAvailable()) { return; }
          try {
            window.webkit.messageHandlers.airwaves.postMessage({
              kind: kind,
              text: String(text == null ? '' : text).slice(0, 4000),
              level: level || 'log'
            });
          } catch (e) {}
        }
      };
    })();
    """

    // ========================================================================
    //  2) 偏好持久化 + 菜单命令执行器（documentEnd）
    //
    //  为什么用 DOM 事件而不是直接调用内部函数：
    //    app.js 是 `(function(global, document){ ... })(window, document)` 形式的
    //    纯 IIFE，内部函数（setBand / setVolume / setMode / …）没有任何对外导出。
    //    所以唯一稳定的挂载点就是它自己注册的那些监听器：
    //
    //      .seg__btn[data-preset]      click        → setBand(preset)
    //      .switch__btn[data-mode]     click        → setMode(mode)
    //      #btn-noise                  click        → setNoise(!state.noise)
    //      #btn-play                   click        → togglePlayback()
    //      #btn-start                  click        → goPlayer()
    //      #btn-back                   click        → goHome()
    //      #beat-range                 input        → setBeat(value, true)
    //      #vol-range                  input        → setVolume(value, {silent:true})
    //
    //    这些交互路径本来就是原 app 的主路径（用户手点也走这里），
    //    因此复用它比另造一条并行通路更安全，也不会与原功能产生第二份状态。
    // ========================================================================

    static let prefsPersistence = """
    (function () {
      'use strict';

      if (window.AirWavesDesktop) { return; }

      var NS = '__airwavesPrefsBridge';
      var bridge = window[NS];
      if (!bridge) { return; }

      var initial = bridge.read() || {};

      function $(id) { return document.getElementById(id); }
      function clamp(v, lo, hi) {
        v = Number(v);
        if (isNaN(v)) { return lo; }
        return v < lo ? lo : (v > hi ? hi : v);
      }
      function fire(el, type) {
        if (!el) { return false; }
        el.dispatchEvent(new Event(type, { bubbles: true }));
        return true;
      }

      // ---------------------------------------------------------------- 写
      // 轻量节流：滑块拖动会连续触发 input，避免每个像素都写一次磁盘
      var lastWrite = 0;
      var pending = null;
      var timer = null;

      function flush() {
        timer = null;
        var patch = pending;
        pending = null;
        if (patch) { bridge.write(patch); }
        lastWrite = Date.now();
      }

      function save(patch) {
        pending = pending || {};
        for (var k in patch) {
          if (Object.prototype.hasOwnProperty.call(patch, k)) { pending[k] = patch[k]; }
        }
        var elapsed = Date.now() - lastWrite;
        if (elapsed > 250) {
          flush();
        } else if (!timer) {
          timer = window.setTimeout(flush, 250 - elapsed);
        }
      }

      // ------------------------------------------------- 状态跟踪 + 落盘
      var lastState = {};

      function observeState() {
        var body = document.body;
        if (!body) { return; }

        var readState = function () {
          var vol = $('vol-range');
          var beatRange = $('beat-range');
          var activeBand = document.querySelector('.seg__btn.is-active');
          var activeMode = document.querySelector('.switch__btn[data-mode].is-active');
          var noise = $('btn-noise');
          var shape = {
            view: body.getAttribute('data-view') || 'home',
            playing: body.getAttribute('data-state') === 'playing',
            volume: vol ? Math.round(parseFloat(vol.value)) : undefined,
            beat: beatRange ? parseFloat(beatRange.value) : undefined,
            band: activeBand ? activeBand.getAttribute('data-preset') : undefined,
            mode: activeMode ? activeMode.getAttribute('data-mode') : undefined,
            noise: noise ? noise.getAttribute('aria-pressed') === 'true' : undefined
          };

          var diff = {};
          var changed = false;
          for (var k in shape) {
            if (!Object.prototype.hasOwnProperty.call(shape, k)) { continue; }
            if (shape[k] === undefined) { continue; }
            if (lastState[k] !== shape[k]) { diff[k] = shape[k]; changed = true; }
          }
          if (!changed) { return; }
          lastState = shape;

          var patch = {
            volume: diff.volume, beat: diff.beat,
            band: diff.band, mode: diff.mode, noise: diff.noise
          };
          // lastView 只在视图真正切换时写，避免被滑块事件顺带覆盖
          if (Object.prototype.hasOwnProperty.call(diff, 'view')) {
            patch.lastView = diff.view;
          }
          for (var p in patch) {
            if (Object.prototype.hasOwnProperty.call(patch, p) && patch[p] === undefined) {
              delete patch[p];
            }
          }
          save(patch);
        };

        // app.js 通过 el.body.setAttribute('data-view' / 'data-state') 更新
        // （见 app.js:146 与 app.js:155），因此属性观察是最可靠的切入点
        new MutationObserver(readState).observe(body, {
          attributes: true,
          attributeFilter: ['data-view', 'data-state']
        });

        // 按钮的 is-active 类与 aria-pressed 变化
        new MutationObserver(readState).observe(document.documentElement, {
          subtree: true,
          attributes: true,
          attributeFilter: ['class', 'aria-pressed']
        });

        // 滑块
        var vol = $('vol-range');
        var beatRange = $('beat-range');
        if (vol) { vol.addEventListener('input', readState); }
        if (beatRange) { beatRange.addEventListener('input', readState); }

        // 首次读一遍，建立基线（此时不写盘）
        readState();
        lastState = lastState || {};
      }

      // ---------------------------------------------------------------- 读
      // 恢复策略：只恢复「参数」与「界面位置」，绝不自动开始播放。
      // 声音必须由用户当次的操作触发，这是 Web Audio 的既定约束，
      // 也是原 app「START → PLAY 两步」设计存在的原因。
      function restore() {
        if (initial.band) {
          var bandBtn = document.querySelector('.seg__btn[data-preset="' + initial.band + '"]');
          if (bandBtn) { bandBtn.click(); }
        }
        if (initial.mode) {
          var modeBtn = document.querySelector('.switch__btn[data-mode="' + initial.mode + '"]');
          if (modeBtn) { modeBtn.click(); }
        }
        if (typeof initial.beat === 'number') {
          var beatRange = $('beat-range');
          if (beatRange) {
            beatRange.value = String(clamp(initial.beat, 4, 18));
            fire(beatRange, 'input');
          }
        }
        if (typeof initial.volume === 'number') {
          var vol = $('vol-range');
          if (vol) {
            vol.value = String(clamp(Math.round(initial.volume), 0, 100));
            fire(vol, 'input');
          }
        }
        if (initial.noise === true) {
          var noiseBtn = $('btn-noise');
          if (noiseBtn && noiseBtn.getAttribute('aria-pressed') !== 'true') {
            noiseBtn.click();
          }
        }
        if (initial.lastView === 'player') {
          var startBtn = $('btn-start');
          if (startBtn) { startBtn.click(); }
        }
      }

      // ------------------------------------------------------------ 命令
      var COMMANDS = {
        'home': function () {
          if (document.body.getAttribute('data-view') !== 'player') { return; }
          var back = $('btn-back');
          if (back) { back.click(); }
        },
        'player': function () {
          if (document.body.getAttribute('data-view') === 'player') { return; }
          var start = $('btn-start');
          if (start) { start.click(); }
        },
        'play': function () {
          // 首页时按「播放」的语义 = 进入播放界面并开始发声
          if (document.body.getAttribute('data-view') !== 'player') {
            document.dispatchEvent(new KeyboardEvent('keydown', {
              key: ' ', code: 'Space', bubbles: true, cancelable: true
            }));
            return;
          }
          var play = $('btn-play');
          if (play) { play.click(); }
        },
        'mute': function () {
          var vol = $('vol-range');
          if (!vol) { return; }
          if (window.__airwavesLastVolume == null) { window.__airwavesLastVolume = 35; }
          var current = Math.round(parseFloat(vol.value));
          var target = current > 0 ? 0 : (window.__airwavesLastVolume || 35);
          if (current > 0) { window.__airwavesLastVolume = current; }
          vol.value = String(target);
          fire(vol, 'input');
        },
        'noise': function () {
          var btn = $('btn-noise');
          if (btn) { btn.click(); }
        },
        'mode-binaural': function () { selectMode('binaural'); },
        'mode-isochronic': function () { selectMode('isochronic'); },
        'band-theta': function () { selectBand('theta'); },
        'band-alpha': function () { selectBand('alpha'); },
        'band-beta': function () { selectBand('beta'); },
        'volume-up': function () { moveVolume(5); },
        'volume-down': function () { moveVolume(-5); },
        'beat-up': function () { moveBeat(0.5); },
        'beat-down': function () { moveBeat(-0.5); },
        'reset-prefs': function () { resetToDefaults(); },
        'appearance-system': function () {},
        'appearance-light': function () {},
        'appearance-dark': function () {}
      };

      function selectBand(key) {
        var btn = document.querySelector('.seg__btn[data-preset="' + key + '"]');
        if (btn) { btn.click(); }
      }

      function selectMode(mode) {
        var btn = document.querySelector('.switch__btn[data-mode="' + mode + '"]');
        if (btn) { btn.click(); }
      }

      function moveVolume(delta) {
        var vol = $('vol-range');
        if (!vol) { return; }
        vol.value = String(clamp(Math.round(parseFloat(vol.value)) + delta, 0, 100));
        fire(vol, 'input');
      }

      function moveBeat(delta) {
        var beatRange = $('beat-range');
        if (!beatRange) { return; }
        var next = Math.round((parseFloat(beatRange.value) + delta) * 2) / 2;
        beatRange.value = String(clamp(next, 4, 18));
        fire(beatRange, 'input');
      }

      function resetToDefaults() {
        selectBand('alpha');
        selectMode('binaural');
        var beatRange = $('beat-range');
        if (beatRange) { beatRange.value = '10'; fire(beatRange, 'input'); }
        var vol = $('vol-range');
        if (vol) { vol.value = '35'; fire(vol, 'input'); }
        var noise = $('btn-noise');
        if (noise && noise.getAttribute('aria-pressed') === 'true') { noise.click(); }
        bridge.reset();
      }

      // ------------------------------------------------- 音频状态上报
      // 把 AudioContext 的关键参数写进日志文件，便于事后排查「没声音」。
      //
      // 为什么用原型探针而不是读引擎实例：app.js 是纯 IIFE，
      // 引擎实例（`var engine`）没有任何对外引用，注入脚本拿不到它。
      // 所以改为在 AudioContext 构造时挂钩，这是唯一稳定可用的观察点。
      (function probeAudio() {
        var Ctor = window.AudioContext || window.webkitAudioContext;
        if (!Ctor || !Ctor.prototype) { return; }
        var patched = false;

        function patch(ctx) {
          if (patched) { return; }
          patched = true;
          var reported = false;
          function report(where) {
            if (reported) { return; }
            reported = true;
            bridge.notify('audio', 'AudioContext 已就绪（' + where + '）: state=' + ctx.state +
              '; sampleRate=' + ctx.sampleRate +
              '; baseLatency=' + (ctx.baseLatency != null ? ctx.baseLatency : 'n/a') +
              '; outputLatency=' + (ctx.outputLatency != null ? ctx.outputLatency : 'n/a'));
          }
          // 原 app 在用户手势里调用 resume()（见 audio.js:320），
          // 这是音频真正开始工作的时刻。
          var originalResume = ctx.resume;
          if (typeof originalResume === 'function') {
            ctx.resume = function () {
              var result = originalResume.apply(ctx, arguments);
              try {
                if (result && typeof result.then === 'function') {
                  result.then(function () { report('resume 成功'); },
                              function (err) {
                                bridge.notify('audio',
                                  'AudioContext.resume 失败: ' + (err && err.message), 'warn');
                              });
                } else {
                  report('resume 返回非 Promise');
                }
              } catch (e) {}
              return result;
            };
          }
          if (ctx.state === 'running') { report('创建时已是 running'); }
        }

        // 直接替换构造函数，保留原型链。
        // 用 new.target 判断调用形式：原 app 是 `new Ctor({...})`（audio.js:156）。
        function Wrapped() {
          var ctx = new.target ? Reflect.construct(Ctor, arguments, new.target) : Ctor.apply(null, arguments);
          patch(ctx);
          return ctx;
        }
        Wrapped.prototype = Ctor.prototype;
        try {
          window.AudioContext = Wrapped;
          if (window.webkitAudioContext) { window.webkitAudioContext = Wrapped; }
        } catch (e) { /* 某些环境下属性只读，忽略即可 */ }
      })();

      // ------------------------------------------------- console 转发
      // 通过原生通道写入日志文件；原生侧还有 forwardConsole 开关可以关掉。
      (function hookConsole() {
        var nativeConsole = window.console;
        if (!nativeConsole) { return; }
        var levels = ['error', 'warn'];
        for (var i = 0; i < levels.length; i++) {
          (function (level) {
            var original = nativeConsole[level];
            nativeConsole[level] = function () {
              var parts = [];
              for (var j = 0; j < arguments.length; j++) {
                var a = arguments[j];
                try {
                  parts.push(typeof a === 'string' ? a : JSON.stringify(a));
                } catch (e) { parts.push(String(a)); }
              }
              bridge.notify('console', parts.join(' '), level);
              if (original) { original.apply(nativeConsole, arguments); }
            };
          })(levels[i]);
        }

        window.addEventListener('error', function (ev) {
          var msg = ev && ev.message ? ev.message : 'unknown error';
          var where = ev && ev.filename ? (' @ ' + ev.filename + ':' + ev.lineno) : '';
          bridge.notify('error', 'page error: ' + msg + where);
        });
        window.addEventListener('unhandledrejection', function (ev) {
          var r = ev && ev.reason;
          bridge.notify('error', 'unhandled rejection: ' + (r && r.message ? r.message : String(r)));
        });
      })();

      // ------------------------------------------------------------ 导出
      window.AirWavesDesktop = {
        bridge: bridge,
        commands: COMMANDS,
        execute: function (name) {
          var handler = COMMANDS[name];
          if (!handler) {
            bridge.notify('error', '未知命令: ' + name, 'warn');
            return false;
          }
          try {
            handler();
            return true;
          } catch (e) {
            bridge.notify('error', '命令执行异常 ' + name + ': ' + (e && e.message), 'error');
            return false;
          }
        },
        // 退出/重载前的清理：让页面自己拆掉音频引擎并触发 beforeunload
        teardown: function () {
          try {
            var engine = window.__airwavesEngine;
            if (engine && typeof engine.destroy === 'function') { engine.destroy(); }
          } catch (e) { /* 忽略：退出路径上不允许抛异常 */ }
          try {
            window.dispatchEvent(new Event('beforeunload'));
          } catch (e) { /* 忽略 */ }
          return true;
        }
      };

      window.AirWavesDesktop.run = function (name) {
        return window.AirWavesDesktop.execute(name);
      };

      // ------------------------------------------------------------ 启动
      function boot() {
        try {
          restore();
          observeState();
          bridge.notify('ready', 'desktop overlay ready; native=' + bridge.native);
        } catch (e) {
          bridge.notify('error', 'overlay 启动失败: ' + (e && e.message), 'error');
        }
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () { window.setTimeout(boot, 0); });
      } else {
        window.setTimeout(boot, 0);
      }
    })();
    """
}

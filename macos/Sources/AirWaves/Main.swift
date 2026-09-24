import AppKit
import SwiftUI

// ============================================================================
//  Air-Waves 私人 macOS 客户端 — 应用入口与生命周期
//
//  为什么用 AppKit 建主窗口而不是 SwiftUI 的 WindowGroup：
//    主窗口的全部内容是 WKWebView。由 AppDelegate 直接创建并持有 NSWindow，
//    webView 的创建时机、加载时机、退出清理时机都可控且可预测——
//    这正是「退出后无残留进程」这条验收项最需要的东西。
//    SwiftUI 只负责偏好设置面板（NSHostingView 承载）。
// ============================================================================

@main
struct AirWavesApp: App {

    // @preconcurrency：AppDelegate 标注了 @MainActor（主线程是唯一正确的
    // 初始化线程），而 NSApplicationDelegate 协议本身未标注隔离。
    // 这个标注显式表明「我知道协议未隔离，适配由我保证」。
    @preconcurrency @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 主窗口由 AppDelegate 直接创建（见文件头说明）。
        // 这里保留一个 Settings scene：SwiftUI 的 App 必须至少有一个 Scene，
        // 而「偏好设置」的实际入口是本工程自建的 NSWindow 面板
        // （见 MenuBuilder.onShowPreferences），不使用这个 scene。
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let prefsStore = PrefsStore.shared
    private var webController: WebController!
    private var menuBuilder: MenuBuilder!
    private var window: NSWindow?
    private var prefsWindow: NSWindow?
    /// 应用是否正在退出：用于区分「关窗口」与「退出应用」
    private var isTerminating = false

    static let defaultWindowSize = NSSize(width: 1180, height: 820)

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("=== Air-Waves 启动 pid=\(ProcessInfo.processInfo.processIdentifier) ===")
        Log.info("系统版本: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        Log.info("Bundle: \(Bundle.main.bundlePath)")

        // 1) 先按需注册外观
        AppearanceManager.apply(prefsStore.current.appearance)

        // 2) 建 WebView（必须在建菜单前，菜单命令要发到它）
        webController = WebController(prefsStore: prefsStore)
        guard webController.makeWebViewIfNeeded() != nil else {
            presentFatalError(
                "应用包内缺少静态资源。\n\n"
                + "预期位置：Contents/Resources/web/index.html\n"
                + "请重新执行 desktop/scripts/build.sh 打包。"
            )
            return
        }

        // 3) 主窗口
        let window = makeMainWindow()
        self.window = window
        webController.attach(window: window)

        // 4) 菜单
        menuBuilder = MenuBuilder(
            sink: webController,
            prefsStore: prefsStore,
            onShowPreferences: { [weak self] in self?.showPreferences() }
        )
        NSApp.mainMenu = menuBuilder.build()
        menuBuilder.syncAppearanceMenu()

        // 5) 加载页面
        window.makeKeyAndOrderFront(nil)
        webController.loadStartPage()

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        Log.info("应用启动完成")

        scheduleSelfTestIfRequested()
    }

    /// 音频自检（仅在设置了环境变量 AIRWAVES_AUTOTEST=1 时启用）。
    ///
    /// 用途：验证「WKWebView 里的 Web Audio 真的能启动」这条最关键的假设。
    /// 这不是自动化测试框架，只是一次可复现的冒烟检查：
    /// 通过注入脚本派发一次合成键盘事件走完 app.js 的真实播放路径，
    /// 注入层会捕获 AudioContext 的最终状态并写进日志文件。
    ///
    /// 用法：
    ///   AIRWAVES_AUTOTEST=1 "build/Air-Waves.app/Contents/MacOS/AirWaves"
    ///   grep -E "audio|AudioContext" ~/Library/Logs/AirWaves/air-waves.log
    private func scheduleSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["AIRWAVES_AUTOTEST"] == "1" else { return }

        let delay = Double(ProcessInfo.processInfo.environment["AIRWAVES_AUTOTEST_DELAY"] ?? "") ?? 2.5
        Log.info("自检模式已启用：将在 \(delay)s 后自动触发播放（仅合成事件，无需真实点击）")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let wv = self?.webController?.webView else { return }
            // 派发合成 Space：走 app.js 自己的 keydown 处理 → goPlayer(true) → startPlayback()
            let js = """
            (function () {
              try {
                document.dispatchEvent(new KeyboardEvent('keydown', {
                  key: ' ', code: 'Space', bubbles: true, cancelable: true
                }));
                return 'dispatched';
              } catch (e) { return 'error: ' + e.message; }
            })();
            """
            wv.evaluateJavaScript(js) { result, error in
                if let error {
                    Log.error("自检：派发键盘事件失败 \(error.localizedDescription)")
                } else {
                    Log.info("自检：已派发播放事件（\(String(describing: result ?? "nil"))），"
                             + "等待音频状态上报…")
                }
            }

            // 再等一会儿收集 AudioContext 状态
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                self?.queryAudioState()
            }
        }
    }

    /// 自检第二步：直接向页面查询音频引擎的真实状态并写进日志
    private func queryAudioState() {
        guard let wv = webController?.webView else { return }
        // app.js 把引擎实例藏在 IIFE 里，拿不到引用，因此这里读的是
        // 「页面自身渲染出来的状态」——即用户肉眼看到的那份真相，
        // 同时把界面控件的值一并读出，用于核对偏好恢复是否生效。
        let js = """
        (function () {
          function v(id) { var e = document.getElementById(id); return e ? e.value : null; }
          function on(sel) {
            var e = document.querySelector(sel);
            return e ? e.getAttribute('data-preset') || e.getAttribute('data-mode') : null;
          }
          var noise = document.getElementById('btn-noise');
          var body = document.body;
          return JSON.stringify({
            view: body.getAttribute('data-view'),
            state: body.getAttribute('data-state'),
            status: (document.getElementById('ro-status') || {}).textContent,
            carrier: (document.getElementById('ro-carrier') || {}).textContent,
            elapsed: (document.getElementById('ro-elapsed') || {}).textContent,
            volume: v('vol-range'),
            beat: v('beat-range'),
            band: on('.seg__btn.is-active'),
            mode: on('.switch__btn[data-mode].is-active'),
            noise: noise ? noise.getAttribute('aria-pressed') : null,
            hasDesktopApi: !!window.AirWavesDesktop,
            nativeBridge: !!(window.__airwavesPrefsBridge && window.__airwavesPrefsBridge.native)
          });
        })();
        """
        wv.evaluateJavaScript(js) { result, error in
            if let error {
                Log.error("自检：读取页面状态失败 \(error.localizedDescription)")
            } else {
                Log.info("自检：页面状态 \(String(describing: result ?? "nil"))")
            }
            Log.info("自检结束")
            Log.shared.flush()
        }
    }

    private func makeMainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Air-Waves"
        window.minSize = NSSize(width: 900, height: 640)
        window.titlebarAppearsTransparent = false
        window.backgroundColor = NSColor(red: 0.020, green: 0.031, blue: 0.047, alpha: 1)

        // 记住窗口位置与大小（存于 UserDefaults，本机）
        window.setFrameAutosaveName("AirWavesMainWindow")
        if window.frame.origin == .zero {
            window.center()
        }

        // WKWebView 填满内容区
        if let wv = webController.webView {
            wv.translatesAutoresizingMaskIntoConstraints = false
            let container = NSView(frame: NSRect(origin: .zero, size: Self.defaultWindowSize))
            container.addSubview(wv)
            NSLayoutConstraint.activate([
                wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                wv.topAnchor.constraint(equalTo: container.topAnchor),
                wv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            window.contentView = container
        }

        window.delegate = self
        return window
    }

    // MARK: 生命周期

    /// 关掉窗口就退出应用 —— 符合「电台类单窗口工具」的直觉预期，
    /// 也保证不会留一个没有界面却在后台发声的进程。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Log.info("最后一个窗口已关闭，准备退出")
        return true
    }

    /// 点 Dock 图标时把窗口找回来
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window {
            window.makeKeyAndOrderFront(nil)
            Log.info("Dock 点击：已重新显示主窗口")
        }
        return true
    }

    /// 退出前统一清理：停止音频、卸载页面、摘掉消息处理器、刷日志。
    ///
    /// 这里返回 .terminateLater 是为了「先清理完再退」，
    /// 避免音频线程在 WebContent 进程里多存活一小段时间。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true

        Log.info("收到退出请求，开始清理")
        webController?.shutdownAndCleanUp()
        prefsWindow?.close()
        Log.info("=== Air-Waves 退出 ===")
        Log.shared.flush()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 兜底：确保日志落盘。
        // 注意这是退出流程的最后一步——如果这一行没出现在日志里，
        // 说明进程是被强制终止的，而不是走完了 AppKit 的正常退出序列。
        Log.info("applicationWillTerminate：退出流程收尾")
        Log.shared.flush()
    }

    // MARK: 偏好设置面板

    private func showPreferences() {
        if let existing = prefsWindow {
            existing.makeKeyAndOrderFront(nil)
            if #available(macOS 14.0, *) { NSApp.activate() }
            else { NSApp.activate(ignoringOtherApps: true) }
            return
        }

        let view = PreferencesView(
            prefsStore: prefsStore,
            onAppearanceChange: { [weak self] mode in
                self?.menuBuilder.syncAppearanceMenu()
                Log.info("偏好面板切换外观: \(mode)")
            },
            onOpenLog: { [weak self] in self?.openLog() },
            onOpenDataDir: { [weak self] in self?.openDataDir() }
        )

        let hosting = NSHostingController(rootView: view)
        let panel = NSWindow(contentViewController: hosting)
        panel.title = "Air-Waves 偏好设置"
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.center()
        prefsWindow = panel

        panel.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        Log.info("偏好设置面板已打开")
    }

    private func openLog() {
        let url = AppPaths.logFile
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func openDataDir() {
        let url = AppPaths.supportDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: 致命错误

    /// 资源缺失等无法继续的情况：给出明确指引而不是空白窗口。
    private func presentFatalError(_ message: String) {
        Log.error("致命错误: \(message.replacingOccurrences(of: "\n", with: " "))")
        let alert = NSAlert()
        alert.messageText = "Air-Waves 无法启动"
        alert.informativeText = message + "\n\n日志：\(AppPaths.logFile.path)"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "退出")
        alert.runModal()
        Log.shared.flush()
        NSApp.terminate(nil)
    }
}

// MARK: - 窗口代理

extension AppDelegate: NSWindowDelegate {

    /// 用户在播放时直接点红色按钮：先把音频停掉再关窗。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window {
            Log.info("主窗口即将关闭，先停止音频")
            // 关窗后应用会退出，退出路径里还会再清理一次；
            // 这里提前停音频可让「先静音、再关窗」的观感更自然。
            webController?.send(MenuCommand.showHome.rawValue)
        }
        return true
    }
}

// MARK: - 偏好设置界面

/// 只承载「macOS 层面」的设置。
/// 音量 / 频段 / Δf 等播放参数留在应用自己的界面里调——
/// 不在这里重复造一套并行控件，避免两份状态互相打架。
struct PreferencesView: View {

    let prefsStore: PrefsStore
    var onAppearanceChange: (String) -> Void
    var onOpenLog: () -> Void
    var onOpenDataDir: () -> Void

    @State private var appearance: String
    @State private var forwardConsole: Bool

    init(prefsStore: PrefsStore,
         onAppearanceChange: @escaping (String) -> Void,
         onOpenLog: @escaping () -> Void,
         onOpenDataDir: @escaping () -> Void) {
        self.prefsStore = prefsStore
        self.onAppearanceChange = onAppearanceChange
        self.onOpenLog = onOpenLog
        self.onOpenDataDir = onOpenDataDir
        _appearance = State(initialValue: prefsStore.current.appearance)
        _forwardConsole = State(initialValue: prefsStore.current.forwardConsole)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            Form {
                Section {
                    Picker("外观", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appearance) { newValue in
                        prefsStore.update { $0.appearance = newValue }
                        AppearanceManager.apply(newValue)
                        onAppearanceChange(newValue)
                    }
                } header: {
                    Text("窗口与菜单外观")
                } footer: {
                    Text("页面本身的深色 CRT 主题是固定的，此设置影响窗口边框与原生控件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("把页面控制台输出写入日志", isOn: $forwardConsole)
                        .onChange(of: forwardConsole) { newValue in
                            prefsStore.update { $0.forwardConsole = newValue }
                            Log.info("console 转发已\(newValue ? "开启" : "关闭")")
                        }
                } header: {
                    Text("诊断")
                } footer: {
                    Text("关闭后可减少日志体积；排查播放问题时建议开启。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 10) {
                Button("打开日志") { onOpenLog() }
                Button("打开数据目录") { onOpenDataDir() }
                Spacer()
            }
            .padding(12)

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text(versionLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("零网络请求 · 数据仅存本机 · 仅供个人使用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: 460)
    }

    private var versionLine: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let rev = Bundle.main.object(forInfoDictionaryKey: "AirWavesSourceRevision") as? String ?? "unknown"
        return "版本 \(v) · 源码版本 \(rev)"
    }
}

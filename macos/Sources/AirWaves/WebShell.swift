import AppKit
import SwiftUI
import WebKit

// ============================================================================
//  WebView 外壳
//
//  与 MenuBuilder 的解耦：菜单只依赖 MessageSink 协议，不认识 WKWebView。
//  这样菜单逻辑可以独立审阅，也便于将来替换 WebView 实现。
// ============================================================================

/// 菜单 → 页面 的单向命令通道
protocol MessageSink: AnyObject {
    /// 发送一条前端命令（对应 prefs.js 里的 COMMANDS 表）
    func send(_ command: String)
    /// 让页面重新载入（可选忽略缓存）
    func reloadPage(ignoringCache: Bool)
    func zoom(_ action: ZoomAction)
    func toggleDevTools()
}

enum ZoomAction {
    case reset, zoomIn, zoomOut
}

// MARK: - 注入的前端脚本

/// 桌面端注入到页面的脚本。
///
/// 为什么用「注入」而不是改原文件：
///   约束是「不破坏原仓库原本的运行方式」。原 index.html / app.js / styles.css
///   保持字节不变，桌面端能力全部通过 WKUserScript 在运行时注入。
///   这样 start.sh / serve.py / 浏览器直开 三种原方式全部照旧可用。
///   脚本本体见 InjectedJS.swift。
enum InjectedScripts {

    /// 1) 首屏配置（documentStart，最早执行）
    static func config(_ prefs: PrefsStore) -> String {
        """
        window.__AIRWAVES_NATIVE__ = \(prefs.javaScriptLiteral);
        """
    }

    /// 2) 原生偏好桥（documentStart）
    static var bridge: String { InjectedJS.prefsBridge }

    /// 3) 偏好持久化 + 菜单命令执行器（documentEnd，等 DOM 与 app.js 就绪）
    static var persistence: String { InjectedJS.prefsPersistence }
}

// MARK: - WebController

final class WebController: NSObject, ObservableObject, MessageSink, WKScriptMessageHandler, WKNavigationDelegate {

    /// SwiftUI 用来承载 WebView（NSViewRepresentable 从这里取实例）
    @Published private(set) var webView: WKWebView?

    private let prefsStore: PrefsStore
    private weak var window: NSWindow?

    /// 记录页面是否已成功加载过，用于区分「首屏失败」与「运行中失败」
    private var didLoadOnce = false
    /// 页面加载失败时的重试次数，避免死循环
    private var loadFailureCount = 0

    private static let messageHandlerName = "airwaves"
    private static let prefsHandlerName = "airwavesPrefs"

    init(prefsStore: PrefsStore) {
        self.prefsStore = prefsStore
        super.init()
    }

    // MARK: 构建

    /// 惰性创建 WKWebView。必须在配置菜单之前调用（菜单依赖 webView 存在）。
    @discardableResult
    func makeWebViewIfNeeded() -> WKWebView? {
        if let existing = webView { return existing }
        guard let root = AppPaths.webRoot else {
            Log.error("装配失败: App 包内缺少 Resources/web 目录")
            return nil
        }
        guard FileManager.default.fileExists(atPath: root.path) else {
            Log.error("装配失败: 资源目录不存在 \(root.path)")
            return nil
        }

        let config = WKWebViewConfiguration()

        // --- 资源协议：不起 HTTP 服务，直接从 App 包读文件 ----------------
        config.setURLSchemeHandler(
            WebAssetSchemeHandler(root: root),
            forURLScheme: kAssetScheme
        )

        // --- 持久化数据仓库 ----------------------------------------------
        // 保留默认的持久化 store：万一将来需要 localStorage 也能工作。
        // （当前偏好设置的唯一真相是原生 UserDefaults，见 Support.swift）
        config.websiteDataStore = .default()

        // --- 媒体与播放策略 ----------------------------------------------
        // 原 app 需要用户手势才启动音频（这是 Web Audio 的正常约束，
        // 也是 START → PLAY 两步交互存在的原因），因此不需要 autoplay 放宽。
        config.mediaTypesRequiringUserActionForPlayback = .audio

        // --- 注入脚本 ----------------------------------------------------
        let ucc = config.userContentController
        ucc.addUserScript(WKUserScript(
            source: InjectedScripts.config(prefsStore),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        ucc.addUserScript(WKUserScript(
            source: InjectedScripts.bridge,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        ucc.addUserScript(WKUserScript(
            source: InjectedScripts.persistence,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        ucc.add(self, name: Self.messageHandlerName)
        ucc.add(self, name: Self.prefsHandlerName)

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.allowsMagnification = true
        wv.allowsBackForwardNavigationGestures = false
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) AirWavesDesktop/1.0 Safari/605.1.15"

        // 背景色对齐原 app 的深色底（#05080c），避免加载瞬间白闪。
        // 只用公开 API（macOS 12+），不碰私有 KVC。
        wv.underPageBackgroundColor = NSColor(red: 0.020, green: 0.031, blue: 0.047, alpha: 1)

        // 禁用 WebKit 的磁盘缓存走查：静态资源很小，直接忽略本地缓存更可控。
        // （原 serve.py 存在的理由就是缓存导致「改了没生效」，这里延续同样的取向）
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, diskPath: nil)

        self.webView = wv
        Log.info("WKWebView 已创建，资源根目录: \(root.path)")
        return wv
    }

    func attach(window: NSWindow) {
        self.window = window
    }

    // MARK: 加载

    func loadStartPage() {
        guard let wv = webView else { return }
        var request = URLRequest(url: kStartURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        Log.info("开始加载 \(kStartURL.absoluteString)")
        wv.load(request)
    }

    // MARK: MessageSink（菜单命令）

    func send(_ command: String) {
        guard let wv = webView, didLoadOnce else {
            Log.warn("菜单命令被忽略（页面尚未就绪）: \(command)")
            return
        }
        // 用 JSON 编码避免任何注入风险：命令字符串来自本工程内的常量表
        let literal = jsString(command)
        wv.evaluateJavaScript("window.AirWavesDesktop && window.AirWavesDesktop.run(\(literal));") { _, error in
            if let error {
                Log.warn("命令执行失败 \(command): \(error.localizedDescription)")
            } else {
                Log.debug("命令已执行: \(command)")
            }
        }
    }

    func reloadPage(ignoringCache: Bool) {
        guard let wv = webView else { return }
        // 先让页面自己拆掉音频引擎，避免残留振荡器；随后再重新载入。
        wv.evaluateJavaScript("window.AirWavesDesktop && window.AirWavesDesktop.teardown();") { [weak self] _, _ in
            guard let self, let wv = self.webView else { return }
            if ignoringCache {
                var request = URLRequest(url: kStartURL)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                wv.load(request)
            } else {
                wv.reload()
            }
            Log.info("页面已重新载入 (忽略缓存: \(ignoringCache))")
        }
    }

    func zoom(_ action: ZoomAction) {
        guard let wv = webView else { return }
        switch action {
        case .reset:   wv.magnification = 1.0
        case .zoomIn:  wv.magnification = min(3.0, wv.magnification + 0.1)
        case .zoomOut: wv.magnification = max(0.5, wv.magnification - 0.1)
        }
    }

    func toggleDevTools() {
        guard let wv = webView else { return }
        if #available(macOS 13.3, *) {
            if wv.isInspectable {
                wv.isInspectable = false
                Log.info("开发者工具已关闭（isInspectable = false）")
            } else {
                wv.isInspectable = true
                Log.info("开发者工具已开启：请右键页面选择「检查元素」")
            }
        }
    }

    // MARK: 退出清理

    /// 退出前显式停止音频并清空页面，确保没有残留的音频线程/振荡器。
    ///
    /// 为什么需要：Web Audio 的振荡器一旦启动就不受「视图销毁」影响，
    /// 只靠进程退出终止会让「先黑屏后静音」的顺序变得不可预期。
    /// 这里主动 destroy() 音频引擎，再导航到 about:blank 卸载页面。
    func shutdownAndCleanUp() {
        guard let wv = webView else { return }
        Log.info("开始清理：停止音频引擎并卸载页面")

        // 等待 JS 回调：不能用 semaphore 阻塞主线程——WebKit 的
        // evaluateJavaScript 回调派发在主线程上，阻塞主线程会导致必然超时。
        // 正确做法是「泵主 RunLoop」直到回调到达或超时。
        var done = false
        wv.evaluateJavaScript("window.AirWavesDesktop && window.AirWavesDesktop.teardown();") { _, _ in
            done = true
        }
        let deadline = Date().addingTimeInterval(1.5)
        if Thread.isMainThread {
            while !done && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        if !done {
            Log.warn("清理：前端 teardown 未在 1.5s 内返回，继续强制卸载")
        }

        // 卸载页面，促使 WebContent 进程释放音频上下文
        wv.stopLoading()
        wv.load(URLRequest(url: URL(string: "about:blank")!))
        detachMessageHandlers()
        Log.info("清理完成")
    }

    /// 注销脚本消息处理器。
    ///
    /// 必要性：WKUserContentController 对 message handler 是强引用，
    /// 而不透明消息发给已释放的对象会抛 Objective-C 异常。
    /// 退出路径上必须显式摘掉。
    private func detachMessageHandlers() {
        guard let ucc = webView?.configuration.userContentController else { return }
        ucc.removeScriptMessageHandler(forName: Self.messageHandlerName)
        ucc.removeScriptMessageHandler(forName: Self.prefsHandlerName)
    }

    deinit {
        detachMessageHandlers()
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
        case Self.prefsHandlerName:
            // 前端上报偏好变化：{patch:{...}}
            guard let body = message.body as? [String: Any] else {
                Log.warn("偏好消息格式异常: \(String(describing: message.body))")
                return
            }
            if body["action"] as? String == "reset" {
                prefsStore.reset()
                Log.info("偏好已由页面请求重置")
                return
            }
            let patch = (body["patch"] as? [String: Any]) ?? body
            prefsStore.apply(patch: patch)
            Log.debug("偏好已更新: \(patch.keys.sorted().joined(separator: ","))")

        case Self.messageHandlerName:
            // 页面 → 原生 的通知
            guard let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String else { return }
            switch kind {
            case "ready":
                Log.info("页面报告就绪（注入脚本已生效）")
            case "console":
                guard prefsStore.current.forwardConsole else { return }
                let level = (body["level"] as? String) ?? "log"
                let text = (body["text"] as? String) ?? ""
                switch level {
                case "error": Log.error("[web] \(text)")
                case "warn":  Log.warn("[web] \(text)")
                default:      Log.debug("[web] \(text)")
                }
            case "audio":
                // 前端把音频引擎的关键状态上报，便于事后排查「没声音」类问题
                let detail = (body["text"] as? String) ?? ""
                Log.info("[audio] \(detail)")
            case "error":
                let text = (body["text"] as? String) ?? "未知页面错误"
                Log.error("[web] \(text)")
            default:
                Log.debug("[web] 未知通知 \(kind)")
            }

        default:
            break
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didLoadOnce = true
        loadFailureCount = 0
        Log.info("页面加载完成")
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        Log.error("页面加载失败（运行时）: \(error.localizedDescription)")
        presentLoadFailure(error)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        Log.error("页面加载失败（首屏）: \(error.localizedDescription)")
        presentLoadFailure(error)
    }

    /// 加载失败时给出可见反馈，而不是留一个白窗口。
    ///
    /// 约定：首屏连续失败 2 次后，注入一段最小的错误说明页，
    /// 提示用户去看日志文件，并给出日志路径。
    private func presentLoadFailure(_ error: Error) {
        loadFailureCount += 1
        guard loadFailureCount >= 2, let wv = webView else { return }

        let logPath = AppPaths.logFile.path
        let message = (error as NSError).localizedDescription
        let html = """
        <!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
        <title>Air-Waves 加载失败</title><style>
        :root{color-scheme:dark}
        body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
        background:#05080c;color:#cfe9f5;font:14px/1.7 -apple-system,"PingFang SC",sans-serif}
        .box{max-width:600px;padding:30px 34px;border:1px solid #1d3a4a;border-radius:10px;
        background:#080d13}
        h1{font-size:17px;margin:0 0 14px;color:#6fe3ff;letter-spacing:.06em}
        .path{display:block;margin:8px 0;padding:9px 11px;background:#0d1620;border-radius:6px;
        color:#8fb6c8;font-family:ui-monospace,Menlo,monospace;font-size:12px;
        word-break:break-all;white-space:pre-wrap}
        p{margin:8px 0;color:#9dbccb}
        ol{margin:6px 0 0;padding-left:20px;color:#9dbccb}
        </style></head><body><div class="box">
        <h1>// SIGNAL LOST — 页面资源加载失败</h1>
        <p>桌面端未能从 App 包内读取静态资源。原始错误：</p>
        <span class="path">\(escapeHTML(message))</span>
        <p>排查建议：</p>
        <ol>
        <li>确认 <b>Contents/Resources/web/index.html</b> 存在（重新执行打包脚本 <b>desktop/scripts/build.sh</b>）</li>
        <li>查看日志：<span class="path">\(escapeHTML(logPath))</span></li>
        <li>用菜单「视图 → 重新载入（忽略缓存）」重试</li>
        </ol>
        </div></body></html>
        """
        wv.loadHTMLString(html, baseURL: nil)
        loadFailureCount = 0  // 允许用户重试
    }

    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

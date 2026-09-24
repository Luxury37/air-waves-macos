import Foundation
import WebKit

// ============================================================================
//  内置资源协议：airwaves://
//
//  为什么需要它（这是整个方案的关键机制）：
//    原项目 README 明确写了「必须通过 http 服务打开，不能直接双击 index.html」——
//    因为 file:// 协议下 WebKit 会拦截子资源（CSS/JS/图片）。
//
//    桌面壳的解法不是「再起一个本地 HTTP 服务」，而是注册一个 WKURLSchemeHandler，
//    由 App 自己从 .app 包内读取文件并回给 WebView。好处：
//      * 不起服务 → 不存在端口占用/端口冲突（原 8765-8769 的端口逻辑彻底不需要）
//      * 不监听任何 socket → 不暴露本机端口，无外部访问面
//      * 资源来自只读的 App 包 → 天然只读，无目录穿越风险之外的面
//
//  安全：解析后的真实路径必须仍在 webRoot 之内，否则一律 403。
//        同时显式拒绝路径中出现 ".."。
// ============================================================================

/// 资源协议名。WKWebView 对自定义 scheme 的要求：首字符为字母，
/// 且只能包含字母、数字、'+'、'-'、'.'（下划线非法）。
let kAssetScheme = "airwaves"

/// 首页地址
let kStartURL = URL(string: "\(kAssetScheme)://local/index.html")!

// MARK: - MIME 类型

/// 按扩展名决定 Content-Type。这里覆盖原项目实际会加载的全部类型：
/// html / css / js / png / jpg / webp / svg / woff2 / json，其余按二进制处理。
private func mimeType(forExtension ext: String) -> String {
    switch ext {
    case "html", "htm":     return "text/html"
    case "css":             return "text/css"
    case "js", "mjs":       return "text/javascript"
    case "json":            return "application/json"
    case "png":             return "image/png"
    case "jpg", "jpeg":     return "image/jpeg"
    case "webp":            return "image/webp"
    case "gif":             return "image/gif"
    case "svg":             return "image/svg+xml"
    case "ico":             return "image/x-icon"
    case "woff":            return "font/woff"
    case "woff2":           return "font/woff2"
    case "ttf":             return "font/ttf"
    case "otf":             return "font/otf"
    case "mp3":             return "audio/mpeg"
    case "wav":             return "audio/wav"
    case "ogg":             return "audio/ogg"
    case "txt", "md":       return "text/plain; charset=utf-8"
    case "wasm":            return "application/wasm"
    default:                return "application/octet-stream"
    }
}

// MARK: - Scheme Handler

final class WebAssetSchemeHandler: NSObject, WKURLSchemeHandler {

    /// App 包内的静态资源根目录（<App>.app/Contents/Resources/web）
    private let root: URL

    /// 标准化的根路径，用于前缀校验
    private let rootPath: String

    init(root: URL) {
        self.root = root.standardizedFileURL
        self.rootPath = root.standardizedFileURL.path
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, code: NSURLErrorBadURL, "请求缺少 URL")
            return
        }

        let relative = Self.relativePath(from: url)

        // --- 目录穿越防护 ------------------------------------------------
        // 客户端已归一化过 '.' / '..'，这里再做一次显式拒绝，双保险。
        if relative.contains("..") {
            Log.warn("资源协议: 拒绝可疑路径 \(url.absoluteString)")
            fail(urlSchemeTask, code: NSURLErrorNoPermissionsToReadFile, "非法路径")
            return
        }

        // 目录请求 → index.html
        let target = relative.isEmpty || relative.hasSuffix("/")
            ? relative + "index.html"
            : relative

        var fileURL = root.appendingPathComponent(target).standardizedFileURL

        // --- 前缀校验：解析结果必须落在 root 之内 ------------------------
        let full = fileURL.path
        guard full == rootPath || full.hasPrefix(rootPath + "/") else {
            Log.warn("资源协议: 越界访问被拒绝 \(full)")
            fail(urlSchemeTask, code: NSURLErrorNoPermissionsToReadFile, "越界访问")
            return
        }

        // 目录（缺少结尾斜杠）→ 尝试其 index.html
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
            fileURL = fileURL.appendingPathComponent("index.html")
        }

        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            // 404 属于正常情况：前端对缺失的备选图有 fallback 逻辑，
            // 这里不记为错误，避免日志噪音。
            Log.debug("资源协议: 未找到 \(target)")
            fail(urlSchemeTask, code: NSURLErrorFileDoesNotExist, "文件不存在: \(target)")
            return
        }

        let ext = fileURL.pathExtension.lowercased()
        let mime = mimeType(forExtension: ext)

        var headers: [String: String] = [
            "Content-Type": mime,
            // 资源随 App 包一起分发，包内容不可变，可安全长缓存。
            // 但为了让「替换图片后立刻生效」，这里仍给一个务实的中等缓存。
            "Cache-Control": "public, max-age=3600",
            "Content-Length": String(data.count),
        ]
        // 图片额外声明，便于 WebKit 走图片解码快路径
        if mime.hasPrefix("image/") {
            headers["X-Content-Type-Options"] = "nosniff"
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            fail(urlSchemeTask, code: NSURLErrorUnknown, "无法构造响应")
            return
        }

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // 读取是同步的，无需取消任何工作。
        // WKWebView 在页面导航离开时会调用这里，不做处理是安全的。
    }

    // MARK: 工具

    /// 从 airwaves://local/a/b.png 提取 "a/b.png"
    ///
    /// 注意 host 部分（示例中的 "local"）被刻意忽略：
    /// 全部资源都以 App 包内的 web/ 为根，host 不参与路径解析，
    /// 这样可以避免 host 被用来绕过根目录限制。
    static func relativePath(from url: URL) -> String {
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        return path.removingPercentEncoding ?? path
    }

    private func fail(_ task: any WKURLSchemeTask, code: Int, _ reason: String) {
        let err = NSError(
            domain: NSURLErrorDomain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
        task.didFailWithError(err)
    }
}

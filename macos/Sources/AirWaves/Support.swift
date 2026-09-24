import AppKit
import Foundation

// ============================================================================
//  Air-Waves 私人 macOS 客户端 — 支撑层
//
//  设计原则：
//    * 完全本机：不发起任何网络请求，不收集任何遥测。
//    * 不污染原项目：所有桌面端代码集中在本文件与同级 Swift 文件中，
//      原仓库的 index.html / app.js / audio.js / styles.css 一行都不改。
//    * 失败必须留下痕迹：写入 ~/Library/Logs/AirWaves/air-waves.log
// ============================================================================

// MARK: - 路径

enum AppPaths {

    /// 应用标识，用于 UserDefaults 套件与数据目录命名。
    static let bundleID = "com.airwaves.private"

    /// 偏好设置：~/Library/Application Support/AirWaves
    static var supportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AirWaves", isDirectory: true)
    }

    /// 日志：~/Library/Logs/AirWaves/air-waves.log
    static var logFile: URL {
        let base = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("AirWaves", isDirectory: true)
            .appendingPathComponent("air-waves.log")
    }

    /// 静态资源根目录：<App>.app/Contents/Resources/web
    static var webRoot: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        return res.appendingPathComponent("web", isDirectory: true)
    }
}

// MARK: - 日志

/// 极简文件日志器。
///
/// 为什么不用 OSLog：本项目要求「错误有日志、可随时翻看」，
/// 纯文本文件对私人使用最直观（Finder 里双击就能看，也能 tail -f）。
///
/// 为什么是同步写：日志最需要它的时刻正是崩溃/异常退出的瞬间，
/// 异步缓冲会丢掉最后几行——那恰恰是唯一有用的几行。
/// 本应用日志量极低（只在启停与错误时写），同步写不构成性能问题。
final class Log {

    static let shared = Log()

    private let lock = NSLock()
    private let formatter: DateFormatter
    private var handle: FileHandle?
    /// 单文件上限 2 MB，超出后轮转为 air-waves.log.1
    private let maxBytes: UInt64 = 2 * 1024 * 1024

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        openHandle()
    }

    private func openHandle() {
        let url = AppPaths.logFile
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }

        // 超限则轮转
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64, size > maxBytes {
            let rotated = url.appendingPathExtension("1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
            fm.createFile(atPath: url.path, contents: nil)
        }

        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func write(_ level: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(level)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }

        var note = ""
        if let h = handle {
            do {
                try h.write(contentsOf: Data(line.utf8))
            } catch {
                // 退出路径上文件句柄可能已被关闭。日志写不进去时，
                // 至少让 stderr 带上原因——但绝不因此中断退出流程。
                note = "  ← 文件写入失败: \(error.localizedDescription)"
            }
        } else {
            note = "  ← 文件句柄不可用"
        }

        // stderr 始终输出，便于从终端直接运行可执行文件时观察
        FileHandle.standardError.write(Data((line + note).utf8))
    }

    static func info(_ m: String)  { shared.write("INFO ", m) }
    static func warn(_ m: String)  { shared.write("WARN ", m) }
    static func error(_ m: String) { shared.write("ERROR", m) }
    static func debug(_ m: String) { shared.write("DEBUG", m) }

    /// 进程退出前把缓冲刷到磁盘
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }
}

// MARK: - 偏好设置

/// 用户偏好。存放于 UserDefaults（本机 ~/Library/Preferences/…），
/// 不写仓库、不上传。
///
/// 注意：字段名刻意与前端 prefs.js 的键名一致，便于互相映射。
struct Prefs: Codable, Equatable {

    // 外观：system | light | dark
    var appearance: String = "system"

    // 播放参数
    var volume: Double = 35
    var beat: Double = 10
    var band: String = "alpha"
    var mode: String = "binaural"
    var noise: Bool = false

    // 会话恢复：home | player（只恢复界面位置，不自动播放）
    var lastView: String = "home"

    // 诊断：是否把前端 console 转发到日志文件
    var forwardConsole: Bool = true

    static let `default` = Prefs()

    // 允许 JSON 中缺少某些键（向后兼容旧版本写入的 blob）
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Prefs.default
        appearance     = (try? c.decode(String.self, forKey: .appearance))     ?? d.appearance
        volume         = (try? c.decode(Double.self, forKey: .volume))         ?? d.volume
        beat           = (try? c.decode(Double.self, forKey: .beat))           ?? d.beat
        band           = (try? c.decode(String.self, forKey: .band))           ?? d.band
        mode           = (try? c.decode(String.self, forKey: .mode))           ?? d.mode
        noise          = (try? c.decode(Bool.self,   forKey: .noise))          ?? d.noise
        lastView       = (try? c.decode(String.self, forKey: .lastView))       ?? d.lastView
        forwardConsole = (try? c.decode(Bool.self,   forKey: .forwardConsole)) ?? d.forwardConsole
    }
}

/// 偏好设置的读写门面。
///
/// 为什么不用前端 localStorage 作为唯一存储：WKWebView 在自定义 URL scheme
/// 下的 localStorage 持久性在不同系统版本上表现不一致。改由原生 UserDefaults
/// 持有唯一真相，前端通过 prefs.js 读写，保证「重启后设置还在」这条硬要求。
final class PrefsStore {

    static let shared = PrefsStore()

    private let defaults: UserDefaults
    private let key = "prefs.v1"
    private let lock = NSLock()
    private var cached: Prefs

    private init() {
        defaults = UserDefaults(suiteName: AppPaths.bundleID) ?? .standard
        cached = Prefs()
        cached = readFromDisk()
        Log.info("PrefsStore 就绪，存储位置: \(AppPaths.supportDirectory.path)")
    }

    private func readFromDisk() -> Prefs {
        guard let data = defaults.data(forKey: key) else {
            Log.info("PrefsStore: 未发现已保存的偏好，使用默认值")
            return .default
        }
        do {
            return try JSONDecoder().decode(Prefs.self, from: data)
        } catch {
            Log.warn("PrefsStore: 偏好解析失败，回退默认值（\(error.localizedDescription)）")
            return .default
        }
    }

    var current: Prefs {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// 返回更新后的完整偏好
    @discardableResult
    func update(_ mutate: (inout Prefs) -> Void) -> Prefs {
        lock.lock()
        var p = cached
        mutate(&p)
        cached = p
        lock.unlock()

        if let data = try? JSONEncoder().encode(p) {
            defaults.set(data, forKey: key)
        }
        return p
    }

    func reset() {
        lock.lock()
        cached = .default
        lock.unlock()
        defaults.removeObject(forKey: key)
        Log.info("PrefsStore: 偏好已重置为默认值")
    }

    // MARK: 前端桥接

    /// 把偏好序列化成可直接注入 JS 的对象字面量。
    var javaScriptLiteral: String {
        let p = current
        // Δf 只保留一位小数，与前端滑块 step=0.5 的精度对齐
        let beat = String(format: "%.1f", clampNum(p.beat, 4, 18))
        return """
        {appearance:\(jsString(p.appearance)),volume:\(clampNum(p.volume, 0, 100)),\
        beat:\(beat),band:\(jsString(p.band)),\
        mode:\(jsString(p.mode)),noise:\(p.noise ? "true" : "false"),\
        lastView:\(jsString(p.lastView)),native:true}
        """
    }

    /// 应用前端上报的偏好补丁。
    ///
    /// 前端只上报发生变化的键，避免用前端的部分状态覆盖原生完整状态。
    func apply(patch: [String: Any]) {
        update { p in
            if let v = patch["appearance"] as? String,
               ["system", "light", "dark"].contains(v) { p.appearance = v }
            if let v = num(patch["volume"]) { p.volume = clampNum(v, 0, 100) }
            if let v = num(patch["beat"])   { p.beat = clampNum(v, 4, 18) }
            if let v = patch["band"] as? String,
               ["theta", "alpha", "beta"].contains(v) { p.band = v }
            if let v = patch["mode"] as? String,
               ["binaural", "isochronic"].contains(v) { p.mode = v }
            if let v = patch["noise"] as? Bool { p.noise = v }
            if let v = patch["lastView"] as? String,
               ["home", "player"].contains(v) { p.lastView = v }
        }
    }

    private func num(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}

// MARK: - 小工具

func clampNum(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    if v.isNaN { return lo }
    return Swift.max(lo, Swift.min(hi, v))
}

/// 转义为安全的 JS 单引号字符串字面量
func jsString(_ s: String) -> String {
    var out = "'"
    for ch in s.unicodeScalars {
        switch ch {
        case "'":  out += "\\'"
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\u{2028}": out += "\\u2028"
        case "\u{2029}": out += "\\u2029"
        default:
            if ch.value < 0x20 {
                out += String(format: "\\u%04x", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out + "'"
}

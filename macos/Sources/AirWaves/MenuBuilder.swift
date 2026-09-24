import AppKit

// ============================================================================
//  原生菜单栏
//
//  设计取向：
//    * 菜单项尽量「直通」原 app 已有的能力，而不是另造一套并行状态。
//      例如「频段 → THETA」等价于点击界面上的 THETA 按钮，
//      走的是 app.js 里那条已经验证过的 setBand('theta') 路径。
//    * 与之配套的快捷键沿用原 app 的键盘约定（1/2/3、↑/↓、←/→），
//      避免用户在两套快捷键之间来回切换记忆。
// ============================================================================

/// 菜单动作。用枚举集中声明，避免散落的 selector 字符串。
enum MenuCommand: String, CaseIterable {
    // 播放控制
    case showHome          = "home"
    case showPlayer        = "player"
    case togglePlayback    = "play"
    case toggleMute        = "mute"
    case toggleNoise       = "noise"
    case setBinaural       = "mode-binaural"
    case setIsochronic     = "mode-isochronic"
    // 频段
    case bandTheta         = "band-theta"
    case bandAlpha         = "band-alpha"
    case bandBeta          = "band-beta"
    // 参数
    case volumeUp          = "volume-up"
    case volumeDown        = "volume-down"
    case beatUp            = "beat-up"
    case beatDown          = "beat-down"
    // 外观
    case appearanceSystem  = "appearance-system"
    case appearanceLight   = "appearance-light"
    case appearanceDark    = "appearance-dark"
    // 其他
    case resetPrefs        = "reset-prefs"
}

final class MenuBuilder: NSObject {

    private weak var sink: MessageSink?
    private let prefsStore: PrefsStore
    /// 打开偏好设置面板。由 AppDelegate 注入，避免依赖响应链与
    /// SwiftUI Settings scene 的注册时序（那条路在「自己建窗口」的
    /// 架构下不可靠）。
    private let onShowPreferences: () -> Void

    /// 外观菜单项的引用，用于打勾
    private var appearanceItems: [String: NSMenuItem] = [:]

    init(sink: MessageSink,
         prefsStore: PrefsStore,
         onShowPreferences: @escaping () -> Void) {
        self.sink = sink
        self.prefsStore = prefsStore
        self.onShowPreferences = onShowPreferences
        super.init()
    }

    // MARK: 构建

    func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenuItem())
        main.addItem(editMenuItem())
        main.addItem(playbackMenuItem())
        main.addItem(bandMenuItem())
        main.addItem(viewMenuItem())
        main.addItem(windowMenuItem())
        main.addItem(helpMenuItem())
        return main
    }

    // MARK: 应用菜单

    private func appMenuItem() -> NSMenuItem {
        let name = "Air-Waves"
        let root = NSMenuItem()
        let menu = NSMenu(title: name)

        menu.addItem(withTitle: "关于 \(name)",
                     action: #selector(showAbout),
                     keyEquivalent: "")
            .target = self

        menu.addItem(.separator())

        // 偏好设置：直接指向自建的设置面板（不用 SwiftUI Settings scene，
        // 因为主窗口是本类自己创建的，Settings scene 的注册时机不可靠）
        let settings = NSMenuItem(
            title: "偏好设置…",
            action: #selector(onShowPreferences(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let services = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)

        menu.addItem(.separator())

        menu.addItem(withTitle: "隐藏 \(name)",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "隐藏其他",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "全部显示",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")

        menu.addItem(.separator())

        // 退出前统一清理（见 AppDelegate.applicationShouldTerminate）
        menu.addItem(withTitle: "退出 \(name)",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        root.submenu = menu
        return root
    }

    // MARK: 编辑菜单（WKWebView 的文本操作依赖它）

    private func editMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "编辑")

        menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())

        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        root.submenu = menu
        return root
    }

    // MARK: 播放菜单

    private func playbackMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "播放")

        add(menu, "返回首页", #selector(onShowHome), "escape", command: .showHome,
            modifiers: [.command])
        add(menu, "进入播放界面", #selector(onShowPlayer), "return", command: .showPlayer,
            modifiers: [.command])

        menu.addItem(.separator())

        add(menu, "播放 / 暂停", #selector(onTogglePlayback), "p", command: .togglePlayback,
            modifiers: [.command, .shift])
        add(menu, "静音", #selector(onToggleMute), "m", command: .toggleMute,
            modifiers: [.command])

        menu.addItem(.separator())

        add(menu, "环境底噪（粉红噪声）", #selector(onToggleNoise), "n", command: .toggleNoise,
            modifiers: [.command])

        menu.addItem(.separator())

        add(menu, "双耳节拍", #selector(onBinaural), "b", command: .setBinaural,
            modifiers: [.command])
        add(menu, "等时节拍", #selector(onIsochronic), "i", command: .setIsochronic,
            modifiers: [.command])

        root.submenu = menu
        return root
    }

    // MARK: 频段菜单

    private func bandMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "频段")

        add(menu, "THETA（6–8 Hz · 深度放松）", #selector(onTheta), "1", command: .bandTheta,
            modifiers: [.command])
        add(menu, "ALPHA（8–12 Hz · 放松专注）", #selector(onAlpha), "2", command: .bandAlpha,
            modifiers: [.command])
        add(menu, "LOW BETA（12–18 Hz · 工作学习）", #selector(onBeta), "3", command: .bandBeta,
            modifiers: [.command])

        menu.addItem(.separator())

        add(menu, "音量 +5%", #selector(onVolumeUp), "=", command: .volumeUp,
            modifiers: [.command])
        add(menu, "音量 −5%", #selector(onVolumeDown), "-", command: .volumeDown,
            modifiers: [.command])

        menu.addItem(.separator())

        add(menu, "Δf +0.5 Hz", #selector(onBeatUp), "]", command: .beatUp,
            modifiers: [.command])
        add(menu, "Δf −0.5 Hz", #selector(onBeatDown), "[", command: .beatDown,
            modifiers: [.command])

        root.submenu = menu
        return root
    }

    // MARK: 显示菜单

    private func viewMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "显示")

        menu.addItem(withTitle: "重新载入",
                     action: #selector(onReload),
                     keyEquivalent: "r").target = self

        let forceReload = NSMenuItem(title: "重新载入（忽略缓存）",
                                     action: #selector(onForceReload),
                                     keyEquivalent: "r")
        forceReload.keyEquivalentModifierMask = [.command, .shift]
        forceReload.target = self
        menu.addItem(forceReload)

        menu.addItem(.separator())

        // 外观
        let appearance = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "外观")
        let choices: [(String, String, Selector)] = [
            ("跟随系统", "system", #selector(onAppearanceSystem)),
            ("浅色",     "light",  #selector(onAppearanceLight)),
            ("深色",     "dark",   #selector(onAppearanceDark)),
        ]
        for (title, key, sel) in choices {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            item.representedObject = key
            appearanceMenu.addItem(item)
            appearanceItems[key] = item
        }
        appearance.submenu = appearanceMenu
        menu.addItem(appearance)

        menu.addItem(.separator())

        menu.addItem(withTitle: "实际大小",
                     action: #selector(onZoomReset),
                     keyEquivalent: "0").target = self
        menu.addItem(withTitle: "放大",
                     action: #selector(onZoomIn),
                     keyEquivalent: "+").target = self
        menu.addItem(withTitle: "缩小",
                     action: #selector(onZoomOut),
                     keyEquivalent: "-").target = self

        menu.addItem(.separator())

        let fullscreen = NSMenuItem(title: "进入全屏",
                                    action: #selector(NSWindow.toggleFullScreen(_:)),
                                    keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullscreen)

        menu.addItem(.separator())

        // 开发者工具默认隐藏：私人使用场景不需要，但排查问题时很有用。
        // 开启后需右键页面选择「检查元素」。
        let devTools = NSMenuItem(title: "开发者工具（可检查元素）",
                                  action: #selector(onToggleDevTools),
                                  keyEquivalent: "i")
        devTools.keyEquivalentModifierMask = [.command, .option]
        devTools.target = self
        menu.addItem(devTools)

        root.submenu = menu
        return root
    }

    // MARK: 窗口菜单

    private func windowMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "窗口")

        menu.addItem(withTitle: "最小化",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "缩放",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "前置全部窗口",
                     action: #selector(NSApplication.arrangeInFront(_:)),
                     keyEquivalent: "")

        NSApp.windowsMenu = menu
        root.submenu = menu
        return root
    }

    // MARK: 帮助菜单

    private func helpMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "帮助")

        menu.addItem(withTitle: "Air-Waves 使用说明",
                     action: #selector(onOpenReadme),
                     keyEquivalent: "?").target = self

        menu.addItem(withTitle: "打开日志文件",
                     action: #selector(onOpenLog),
                     keyEquivalent: "").target = self

        menu.addItem(withTitle: "打开数据目录",
                     action: #selector(onOpenDataDir),
                     keyEquivalent: "").target = self

        menu.addItem(.separator())

        menu.addItem(withTitle: "重置为默认设置",
                     action: #selector(onResetPrefs),
                     keyEquivalent: "").target = self

        NSApp.helpMenu = menu
        root.submenu = menu
        return root
    }

    // MARK: 辅助

    @discardableResult
    private func add(_ menu: NSMenu,
                     _ title: String,
                     _ selector: Selector,
                     _ key: String,
                     command: MenuCommand,
                     modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.representedObject = command.rawValue
        item.toolTip = command.rawValue
        menu.addItem(item)
        return item
    }

    /// 同步外观菜单的勾选状态
    func syncAppearanceMenu() {
        let current = prefsStore.current.appearance
        for (key, item) in appearanceItems {
            item.state = (key == current) ? .on : .off
        }
    }

    // MARK: 动作转发
    //
    // 每个菜单项一个 selector 会让代码膨胀，这里统一从 representedObject
    // 取回 MenuCommand 再转发给页面。

    private func fire(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = MenuCommand(rawValue: raw) else {
            Log.warn("菜单项缺少有效命令: \(sender.title)")
            return
        }
        sink?.send(command.rawValue)
    }

    @objc private func onShowHome(_ s: NSMenuItem)          { fire(s) }
    @objc private func onShowPlayer(_ s: NSMenuItem)        { fire(s) }
    @objc private func onTogglePlayback(_ s: NSMenuItem)    { fire(s) }
    @objc private func onToggleMute(_ s: NSMenuItem)        { fire(s) }
    @objc private func onToggleNoise(_ s: NSMenuItem)       { fire(s) }
    @objc private func onBinaural(_ s: NSMenuItem)          { fire(s) }
    @objc private func onIsochronic(_ s: NSMenuItem)        { fire(s) }
    @objc private func onTheta(_ s: NSMenuItem)             { fire(s) }
    @objc private func onAlpha(_ s: NSMenuItem)             { fire(s) }
    @objc private func onBeta(_ s: NSMenuItem)              { fire(s) }
    @objc private func onVolumeUp(_ s: NSMenuItem)          { fire(s) }
    @objc private func onVolumeDown(_ s: NSMenuItem)        { fire(s) }
    @objc private func onBeatUp(_ s: NSMenuItem)            { fire(s) }
    @objc private func onBeatDown(_ s: NSMenuItem)          { fire(s) }

    // MARK: 视图/帮助动作

    @objc private func onShowPreferences(_ s: Any?) { onShowPreferences() }
    @objc private func onReload(_ s: Any?)      { sink?.reloadPage(ignoringCache: false) }
    @objc private func onForceReload(_ s: Any?) { sink?.reloadPage(ignoringCache: true) }
    @objc private func onZoomReset(_ s: Any?)   { sink?.zoom(.reset) }
    @objc private func onZoomIn(_ s: Any?)      { sink?.zoom(.zoomIn) }
    @objc private func onZoomOut(_ s: Any?)     { sink?.zoom(.zoomOut) }
    @objc private func onToggleDevTools(_ s: Any?) { sink?.toggleDevTools() }

    @objc private func onAppearanceSystem(_ s: NSMenuItem) { setAppearance("system") }
    @objc private func onAppearanceLight(_ s: NSMenuItem)  { setAppearance("light") }
    @objc private func onAppearanceDark(_ s: NSMenuItem)   { setAppearance("dark") }

    private func setAppearance(_ mode: String) {
        prefsStore.update { $0.appearance = mode }
        syncAppearanceMenu()
        AppearanceManager.apply(mode)
        Log.info("外观已切换为 \(mode)")
    }

    @objc private func onResetPrefs(_ s: Any?) {
        let alert = NSAlert()
        alert.messageText = "重置为默认设置？"
        alert.informativeText = "将把音量、频段、Δf、播放模式与外观恢复为默认值。"
            + "该操作不影响 App 内的任何文件。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        prefsStore.reset()
        sink?.send(MenuCommand.resetPrefs.rawValue)
        syncAppearanceMenu()
        AppearanceManager.apply(prefsStore.current.appearance)
        Log.info("用户已重置偏好设置")
    }

    @objc private func onOpenReadme(_ s: Any?) {
        // 打开 App 包内的说明文件；打包脚本会把 README / START.md 复制进去
        if let url = Bundle.main.url(forResource: "客户端说明", withExtension: "md")
            ?? Bundle.main.url(forResource: "使用说明", withExtension: "md")
            ?? Bundle.main.url(forResource: "README", withExtension: "md") {
            NSWorkspace.shared.open(url)
        } else if let dir = AppPaths.webRoot {
            NSWorkspace.shared.open(dir)
        } else {
            Log.warn("未找到说明文件")
        }
    }

    @objc private func onOpenLog(_ s: Any?) {
        let url = AppPaths.logFile
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    @objc private func onOpenDataDir(_ s: Any?) {
        let url = AppPaths.supportDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: 关于面板

    @objc private func showAbout(_ s: Any?) {
        let credits = NSMutableAttributedString(string: """
        Air-Waves 私人 macOS 客户端
        由本机源码构建，仅供个人使用，不对外分发。

        原始网页应用：Air-Waves（上游作者 Luxury37）
        上游仓库未附带许可证，默认保留所有权利；
        本客户端为个人本地修改版本，未获授权再分发。

        音频：Web Audio API 实时合成，无音频文件
        网络：零网络请求，不收集任何数据
        免责：非医疗设备，仅用于放松与专注辅助。
        """)
        credits.addAttributes([
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ], range: NSRange(location: 0, length: credits.length))

        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Air-Waves",
            .applicationVersion: Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            .version: "私人构建 · 源码版本 "
                + (Bundle.main.object(forInfoDictionaryKey: "AirWavesSourceRevision") as? String ?? "unknown"),
            .credits: credits,
        ]
        // applicationIconImage 是 null_resettable，显式判空避免隐式解包
        if let icon = NSApp.applicationIconImage {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - 外观应用

/// 把 system/light/dark 映射到 AppKit 外观。
///
/// 注意：原 app 本身是固定的深色 CRT 主题（index.html 内写死
/// `<meta name="color-scheme" content="dark">`），页面配色不随系统变化。
/// 这里控制的是「窗口外框 + 原生控件 + 菜单栏」的外观，
/// 深色模式下视觉最统一，因此默认仍按系统走。
enum AppearanceManager {

    static func apply(_ mode: String) {
        let appearance: NSAppearance?
        switch mode {
        case "light": appearance = NSAppearance(named: .aqua)
        case "dark":  appearance = NSAppearance(named: .darkAqua)
        default:      appearance = nil  // 跟随系统
        }

        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
        Log.debug("AppearanceManager 已应用: \(mode)")
    }
}

# Air-Waves 私人 macOS 客户端

把上游的 [Air-Waves](https://github.com/Luxury37/Air-Waves) 纯静态网页应用，包装成一个可双击运行的
macOS 原生 `.app`。

**仅供本机个人使用，不对外分发。** 详见文末[许可与合规](#许可与合规)。

---

## 1. 快速开始

```bash
# 进入桌面端目录
cd /Users/16igoing/Documents/Air-waves/desktop

# 一步到位：构建 + 安装到 /Applications
./scripts/build.sh --install

# 运行
open "/Applications/Air-Waves.app"
```

打包 DMG（用于备份或转移到另一台 Mac）：

```bash
./scripts/make_dmg.sh
# 产物：desktop/build/Air-Waves-1.0.0.dmg
```

---

## 2. 它是什么

| 项目 | 说明 |
|---|---|
| 形态 | 原生 macOS `.app`（Dock 图标、菜单栏、快捷键、独立窗口） |
| 体积 | `.app` 约 19 MB，`.dmg` 约 19 MB |
| 技术栈 | SwiftUI + WKWebView（AppKit 管窗口与菜单） |
| 依赖 | **无**。不需要 Rust、不需要 Node、不需要 Python 运行时、不需要 Homebrew |
| 网络 | **零网络请求**。不收集任何数据、不上传任何内容 |
| 端口 | **不占用任何端口**。不起本地 HTTP 服务 |
| 最低系统 | macOS 13.0 |
| 架构 | arm64（Apple Silicon） |

### 为什么改成 .app

原项目要求「必须通过 http 服务打开，不能直接双击 index.html」——因为 `file://` 协议下
浏览器会拦截子资源。桌面端没有沿用「再起一个本地服务」的思路，而是注册了一个
自定义资源协议（`airwaves://`），由 App 自己从包内读取文件交给 WebView。带来三个直接好处：

1. **不存在端口占用或冲突**——原 `start.sh` 里 8765–8769 的端口探测逻辑彻底不需要了
2. **不监听任何 socket**——没有对外暴露的访问面
3. **资源来自只读的 App 包**——天然只读

### 原项目功能与用法完全保留

音频引擎、界面、交互一行都没改。原来怎么用，现在还怎么用：

- 打开后点 **START** 进入播放界面（此时不出声）
- 再点 **PLAY** 开始发声（Web Audio 要求用户手势触发，这是既定约束）
- 键盘：`Space` 播放/暂停 · `M` 静音 · `Esc` 返回 · `1/2/3` 切频段 · `↑/↓` 音量 · `←/→` Δf

---

## 3. 桌面端新增能力

### 3.1 原生菜单栏

| 菜单 | 内容 | 快捷键 |
|---|---|---|
| **Air-Waves** | 关于（含版权与免责说明）、偏好设置、隐藏、退出 | `⌘,` `⌘Q` |
| **编辑** | 撤销/重做/剪切/拷贝/粘贴/全选 | 标准 |
| **播放** | 返回首页 · 进入播放界面 · 播放/暂停 · 静音 · 环境底噪 | `⌘Esc` `⌘↩` `⌘⇧P` `⌘M` `⌘N` |
| | 双耳节拍 / 等时节拍 | `⌘B` `⌘I` |
| **频段** | THETA / ALPHA / LOW BETA | `1` `2` `3` |
| | 音量 +5% / −5% | `=` `-` |
| | Δf +0.5 Hz / −0.5 Hz | `]` `[` |
| **显示** | 重新载入 · 重新载入（忽略缓存） · 外观 · 缩放 · 全屏 · 开发者工具 | `⌘R` `⌘⇧R` `⌘0` `⌘+` `⌘-` `⌃⌘F` `⌥⌘I` |
| **窗口** | 最小化 / 缩放 / 前置全部窗口 | `⌘M` |
| **帮助** | 使用说明 · 打开日志 · 打开数据目录 · 重置为默认设置 | `⌘?` |

频段与参数类快捷键刻意沿用原 app 的键盘约定（`1/2/3`、`]`/`[`），避免在两套记忆之间切换。
菜单命令走的是原 app 自己的交互路径（等价于点击界面上的对应控件），不另造并行状态。

### 3.2 偏好设置（`⌘,`）

- **外观**：跟随系统 / 浅色 / 深色
- **诊断**：是否把页面控制台输出写入日志
- 快捷入口：打开日志、打开数据目录

播放参数（音量/频段/Δf/模式/底噪）**不需要**在偏好面板里再配一套——它们直接由应用界面控制，
并且会**自动记住**：下次启动时原样恢复，包括你上次停在首页还是播放页。

> 恢复时**不会自动开始播放**。声音必须由你当次操作触发。

### 3.3 数据与日志位置

| 内容 | 路径 |
|---|---|
| 日志 | `~/Library/Logs/AirWaves/air-waves.log`（超 2 MB 自动轮转为 `.log.1`） |
| 偏好设置 | 系统 `UserDefaults`，域 `com.airwaves.private` |
| 数据目录 | `~/Library/Application Support/AirWaves/` |

查看日志：

```bash
tail -f ~/Library/Logs/AirWaves/air-waves.log
```

### 3.4 退出行为

关闭窗口即退出应用（单窗口工具的直觉预期），并且会：

1. 主动调用音频引擎的 `destroy()` 停掉所有振荡器
2. 把页面导航到 `about:blank`，促使 WebContent 进程释放音频上下文
3. 注销脚本消息处理器
4. 把日志刷到磁盘

若应用在运行中卡死：

```bash
pkill -f "Air-Waves.app"
```

---

## 4. 常用命令

全部在 `desktop/` 目录下执行。

```bash
# 构建（默认只打包被引用的图片）
./scripts/build.sh

# 清理后重建（改了资源或图标时用）
./scripts/build.sh --clean

# 构建并安装到 /Applications
./scripts/build.sh --install

# 开发：退出旧实例 → 重建 → 启动 → 跟踪日志（Ctrl+C 只停止跟踪，不退出 App）
./scripts/dev.sh

# 开发：音频自检（自动触发一次播放并记录 AudioContext 真实状态）
./scripts/dev.sh --test

# 前台运行，直接看终端输出
./scripts/dev.sh --stdout

# 退出正在运行的实例
./scripts/dev.sh --kill

# 只看日志
./scripts/dev.sh --log

# 打包 DMG
./scripts/make_dmg.sh

# 打包 DMG 并挂载检查
./scripts/make_dmg.sh --mount

# 验收自检（33 项自动化检查）
./scripts/verify.sh

# 只重新装配静态资源（不编译，快速验证资源筛选结果）
python3 scripts/stage_web.py --list

# 只重新生成图标（默认裁成 macOS 规格的圆角矩形；--preview 导出对照图）
python3 scripts/make_icons.py --preview
python3 scripts/make_icons.py --radius 0.18 --preview   # 自定义圆角大小
python3 scripts/make_icons.py --square                  # 保留上游原始方形外观
```

---

## 5. 目录结构

```
desktop/
├── macos/
│   ├── Sources/AirWaves/
│   │   ├── Main.swift        应用入口、AppDelegate、生命周期、偏好设置面板
│   │   ├── MenuBuilder.swift 原生菜单栏、快捷键、关于面板、外观切换
│   │   ├── WebShell.swift    WKWebView 创建、注入配置、命令通道、加载失败兜底
│   │   ├── WebAssets.swift   airwaves:// 自定义资源协议（含目录穿越防护）
│   │   ├── InjectedJS.swift  注入到页面的 JS（偏好桥 + 命令执行器）
│   │   └── Support.swift     日志、偏好存储、路径
│   └── Resources/Info.plist
├── scripts/
│   ├── build.sh       构建 .app
│   ├── dev.sh         开发运行
│   ├── make_dmg.sh    打包 .dmg
│   ├── verify.sh      验收自检
│   ├── stage_web.py   静态资源装配（自动筛选被引用的图片）
│   └── make_icons.py  图标生成（.ico → .icns）
├── build/             构建产物（已 gitignore）
└── README.md          本文件
```

---

## 6. 设计说明

### 6.1 为什么不修改原项目文件

约束是「不破坏原仓库原本的运行方式」。所以：

- `index.html` / `app.js` / `audio.js` / `styles.css` **一个字节都没改**
- 桌面端能力全部通过 `WKUserScript` 在运行时注入
- 原项目的 `start.sh` / `serve.py` / 浏览器直开 三种方式**继续可用**

可以用这条命令随时确认这一点：

```bash
git diff main -- index.html app.js audio.js styles.css serve.py start.sh
# 期望：无任何输出
```

### 6.2 为什么用 DOM 事件驱动菜单命令

`app.js` 是 `(function(global, document){ … })(window, document)` 形式的纯 IIFE，
内部函数（`setBand` / `setVolume` / `setMode` / …）**没有任何对外导出**。
因此唯一稳定的挂载点就是它自己注册的那些监听器：

```
.seg__btn[data-preset]   click  → setBand(preset)
.switch__btn[data-mode]  click  → setMode(mode)
#btn-noise               click  → setNoise(!state.noise)
#btn-play                click  → togglePlayback()
#beat-range              input  → setBeat(value, true)
#vol-range               input  → setVolume(value, {silent:true})
```

这些本来就是原 app 的主交互路径（用户手点也走这里），复用它比另造一条并行通路更安全。

状态跟踪用 `MutationObserver` 监听 `body[data-view]` / `body[data-state]`
（对应 `app.js:146` 与 `app.js:155` 的 `setAttribute` 调用）。

### 6.3 为什么偏好设置存在原生侧

`WKWebView` 在自定义 URL scheme 下的 `localStorage` 持久性在不同系统版本上表现不一致，
而「重启后设置还在」是硬要求。因此以原生 `UserDefaults` 为唯一真相，
前端通过 `WKScriptMessageHandler` 读写。

没有原生桥时（例如用浏览器直接打开 `desktop/build/web/index.html`）
会自动降级到 `localStorage`，同一份注入脚本两种环境都能工作。

### 6.4 静态资源自动筛选

`assets/` 里有 12 张图共 52 MB，但代码只引用其中 3 张。
`stage_web.py` 用正则从 `styles.css` / `app.js` 里提取实际引用路径，自动排除未引用的图，
**省下 35.5 MB**。上游若改了引用，重新打包会自动跟上，不需要改清单。

想强制全量打包：

```bash
./scripts/build.sh --all-assets
```

### 6.5 日志为什么是同步写

日志最需要它的时刻正是崩溃或异常退出的瞬间，异步缓冲会丢掉最后几行——
那恰恰是唯一有用的几行。本应用日志量极低（只在启停与错误时写），同步写不构成性能问题。

### 6.6 图标形状：圆角矩形（squircle）

上游素材是一张**满幅方形图**（`Air-Waves.ico`，无 alpha 通道）。
直接拿来做 macOS 图标会得到一个「硬边方角」的图标，在 Dock 里与系统原生图标并排时很突兀。
因此 `make_icons.py` 会把它裁成 **macOS Big Sur+ 的图标形状**：

- **圆角半径 = 边长 × 0.2237**（Apple 的图标网格规格）
- 圆角外**透明**，Dock 与 Finder 会透出桌面背景
- 每个尺寸**单独裁剪**（不是先裁大图再缩小）——否则小尺寸下圆角比例会失真
- 遮罩按 **4 倍超采样**绘制后缩回，边缘有平滑渐变；16px 下也做了抗锯齿

> **为什么不是「四分之一圆弧 + 直线」的普通圆角矩形？**
> Apple 从 Big Sur 起用的是**连续曲率的超椭圆**（squircle）。
> 普通圆弧圆角在直线与圆弧的接缝处存在曲率突变，视觉上更「硬」，
> 与系统图标并排能看出差别。本脚本用圆角矩形叠加幂次映射逼近连续曲率，
> 实测轮廓（圆角比 0.215、角点对角线内缩 0.068）与 macOS 原生规格吻合。

自己调整形状：

```bash
cd desktop

# 默认：macOS 规格圆角
python3 scripts/make_icons.py --preview

# 自定义圆角大小（0.5 = 接近圆形，0.1 = 接近方形）
python3 scripts/make_icons.py --radius 0.18 --preview

# 保留上游原始方形外观（不做圆角裁剪）
python3 scripts/make_icons.py --square --preview

# 改完形状后必须重新构建才会进 App
./scripts/build.sh --install
```

`--preview` 会额外在 `build/` 下导出两张对照图：

| 文件 | 用途 |
|---|---|
| `icon-preview-512.png` | 512×512 图标本体（带透明外角） |
| `icon-preview-bg.png` | 左浅底 / 右深底对照图，用于确认圆角与透明区正常 |

### 6.7 音频自检模式

```bash
AIRWAVES_AUTOTEST=1 "desktop/build/Air-Waves.app/Contents/MacOS/AirWaves"
```

会在启动 2.5 秒后派发一次合成键盘事件，走完 `app.js` 的真实播放路径，
然后把 `AudioContext` 状态与左右声道载波写进日志。用于验证
「WKWebView 里的 Web Audio 真的能工作」这条最关键的假设。

预期看到：

```
[audio] AudioContext 已就绪（resume 成功）: state=running; sampleRate=44100; baseLatency=0.0029…; outputLatency=0.333…
自检：页面状态 {"view":"player","state":"playing","carrier":"L 200.0 / R 210.0 Hz", …}
```

左右声道载波差应等于当前 Δf（ALPHA 频段默认 10 Hz）。

---

## 7. 已知限制

| 限制 | 说明 | 影响 |
|---|---|---|
| **图标是低清占位** | 上游 `.ico` 最高只有 256×256 且无 alpha 通道，放大到 512/1024 会偏软 | 外观。想换：把任意 ≥1024×1024 的方形 PNG 放到 `macos/Resources/icon-source.png`，重跑 `build.sh` 即可，**无需改代码** |
| 仅 arm64 | 构建脚本写死 `arm64-apple-macos13.0` | 在 Intel Mac 上需要把 `--target` 改成 `x86_64-apple-macos13.0`，或用 `universal` 双架构 |
| 仅简体中文界面 | 桌面端新增的菜单与偏好面板是中文；原 app 界面本身也是中文 | 无 |
| 应用内界面不跟随系统深浅色 | 原 app 是固定深色 CRT 主题（`index.html` 里写死 `color-scheme: dark`） | 「外观」设置影响的是窗口边框与原生控件，不是页面配色 |
| 未做公证（notarization） | ad-hoc 签名，不是 Apple 开发者签名 | 本机构建的可直接打开；**若通过网盘/邮件传到别的 Mac**，需 `xattr -dr com.apple.quarantine` |

### 无法签名时的本地绕过

本方案用 ad-hoc 签名（`codesign -s -`），私人使用足够，**不需要 99 美元/年的 Apple 开发者账号**。

本机构建的 App 通常双击即可打开（文件没有隔离标记）。若遇到拦截：

```bash
# 方式一：去掉隔离标记（从网盘/压缩包传来的文件需要）
xattr -dr com.apple.quarantine /Applications/Air-Waves.app

# 方式二：系统设置 → 隐私与安全性 → 找到被拦截的提示 → 点「仍要打开」

# 方式三：命令行直接启动（绕过 LaunchServices 的检查）
/Applications/Air-Waves.app/Contents/MacOS/AirWaves

# 查看当前签名状态
codesign -dv /Applications/Air-Waves.app
```

---

## 8. 故障排查

| 现象 | 排查 |
|---|---|
| 打开是白窗口 | 看日志 `~/Library/Logs/AirWaves/air-waves.log`；菜单「显示 → 重新载入（忽略缓存）」重试。首屏连续失败 2 次会显示带指引的错误页 |
| 没有声音 | 确认戴了耳机、点了 PLAY、系统音量与输出设备正确。日志里搜 `[audio]`，应看到 `state=running`。若为 `suspended`，点一下页面任意位置 |
| 界面切换后背景图不显示 | 重新打包：`./scripts/build.sh --clean`（`stage_web.py` 会校验引用完整性） |
| 想彻底重置 | 菜单「帮助 → 重置为默认设置」，或 `defaults delete com.airwaves.private` |
| 编译报 `swiftc not found` | `xcode-select --install` |
| 图标生成失败 | `pip3 install --user Pillow` |
| 端口被占用 | **不会发生**——本方案不监听任何端口。若 `start.sh` 起的旧服务还占着 8765，那是原项目的服务，与 App 无关 |
| 想看进程 | `pgrep -fl Air-Waves`（正常情况：退出后应为空） |

---

## 9. 许可与合规

- 上游仓库 **[Luxury37/Air-Waves](https://github.com/Luxury37/Air-Waves) 未附带任何 LICENSE 文件**，
  按默认规则属于「保留所有权利（All Rights Reserved）」。
- 本桌面端是**个人本地修改版本**：仅在你自己的机器上构建、使用。
- **请勿**公开分发本 `.app`/`.dmg`，**请勿**上传到任何仓库或网盘，
  **请勿**将仓库中的美术素材（`assets/` 下的场景图与人物图）另行再利用。
- 本客户端为个人使用而做，未获上游作者的分发授权。

### 隐私

- **零网络请求**：前端代码内无任何外部 URL，桌面端也不发起网络调用
- **零遥测**：不收集、不上传任何数据
- **数据仅存本机**：日志与偏好都在你自己的 `~/Library` 下
- **无密钥**：整个项目不含任何 token、cookie、私钥、API key
  （`verify.sh` 会自动检查这一项）

### 免责声明

本工具仅用于放松与专注辅助，**非医疗设备**，不用于诊断、治疗或预防任何疾病。
双耳节拍的主观感受因人而异，如出现头晕、耳鸣或任何不适，请立即停止使用。

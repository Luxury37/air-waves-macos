# Air-Waves · macOS 客户端

把 [Air-Waves](https://github.com/Luxury37/Air-Waves)（纯静态网页版听觉节拍发生器）包装成
**原生 macOS 应用**：独立窗口、Dock 图标、原生菜单与快捷键、偏好设置持久化、日志、退出清理。

**本仓库只包含 macOS 客户端外壳。** 网页应用本身（`index.html` / `app.js` / `audio.js` /
`styles.css` 与 `assets/` 素材）不在本仓库内，构建时从同级目录读取。

|  |  |
|---|---|
| 技术栈 | SwiftUI + WKWebView（AppKit 管窗口与菜单） |
| 依赖 | **无**。不需要 Rust、Node、Python 运行时、Homebrew |
| 产物 | `.app` 约 19 MB，`.dmg` 约 19 MB |
| 最低系统 | macOS 13.0 |
| 架构 | arm64（Apple Silicon） |
| 网络 | **零网络请求** |
| 端口 | **不占用任何端口**（不起本地 HTTP 服务） |

---

## 快速开始

### 1. 准备目录布局

本客户端需要一个 Air-Waves 网页应用源码目录，两者**并列放置**：

```
Documents/
├── Air-Waves/            ← 网页应用
│   ├── index.html
│   ├── app.js
│   ├── audio.js
│   ├── styles.css
│   └── assets/
└── air-waves-macos/      ← 本仓库
    ├── macos/
    └── scripts/
```

```bash
cd ~/Documents
git clone https://github.com/Luxury37/Air-Waves.git
git clone git@github.com:Luxury37/air-waves-macos.git
```

> 也支持把本仓库放进网页应用内部（`Air-Waves/desktop/`）。
> 或用 `AIRWAVES_WEB_ROOT=/path/to/Air-Waves` 显式指定位置。

### 2. 构建并安装

```bash
cd air-waves-macos

./scripts/build.sh --install     # 构建 + 安装到 /Applications
open "/Applications/Air-Waves.app"
```

### 3. 打包 DMG（可选）

```bash
./scripts/make_dmg.sh
# 产物：build/Air-Waves-1.0.0.dmg
```

---

## 常用命令

```bash
./scripts/build.sh                  # 构建 .app
./scripts/build.sh --clean          # 清理后重建（改了资源或图标时用）
./scripts/build.sh --install        # 构建并安装到 /Applications
./scripts/build.sh --all-assets     # 打包 assets/ 全部图片（默认只打包被引用的）

./scripts/dev.sh                    # 开发：退出旧实例 → 重建 → 启动 → 跟日志
./scripts/dev.sh --test             # 音频自检（自动触发播放并记录 AudioContext 状态）
./scripts/dev.sh --stdout           # 前台运行，直接看终端输出
./scripts/dev.sh --kill             # 退出正在运行的实例

./scripts/make_dmg.sh               # 打包 DMG
./scripts/make_dmg.sh --mount       # 打包 DMG 并挂载检查

./scripts/verify.sh                 # 验收自检（33 项自动化检查）

# 图标（默认裁成 macOS 规格的圆角矩形）
python3 scripts/make_icons.py --preview
python3 scripts/make_icons.py --radius 0.18 --preview   # 自定义圆角
python3 scripts/make_icons.py --square                  # 保留原始方形

# 只重新装配静态资源（快速验证资源筛选结果）
python3 scripts/stage_web.py --list
```

---

## 应用能力

### 原生菜单栏

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

频段与参数类快捷键刻意沿用网页应用原有的键盘约定（`1/2/3`、`]`/`[`），
菜单命令走的是网页应用自己的交互路径（等价于点击界面上对应控件），不另造并行状态。

### 偏好设置（`⌘,`）

外观（跟随系统 / 浅色 / 深色）、诊断日志开关、日志与数据目录快捷入口。

播放参数（音量 / 频段 / Δf / 模式 / 底噪）由应用界面直接控制，
并会**自动记住**：下次启动时原样恢复，包括上次停在首页还是播放页。
恢复时**不会自动开始播放**——声音必须由当次操作触发。

### 数据与日志

| 内容 | 路径 |
|---|---|
| 日志 | `~/Library/Logs/AirWaves/air-waves.log`（超 2 MB 自动轮转） |
| 偏好设置 | 系统 `UserDefaults`，域 `com.airwaves.private` |
| 数据目录 | `~/Library/Application Support/AirWaves/` |

```bash
tail -f ~/Library/Logs/AirWaves/air-waves.log
```

### 退出行为

关闭窗口即退出应用，并会：停止音频引擎的所有振荡器 → 把页面导航到 `about:blank`
促使 WebContent 进程释放音频上下文 → 注销脚本消息处理器 → 把日志刷到磁盘。

---

## 设计要点

### 不修改网页应用任何文件

`index.html` / `app.js` / `audio.js` / `styles.css` **一个字节都不改**。
桌面端能力全部通过 `WKUserScript` 在运行时注入，
因此网页应用原有的 `start.sh` / `serve.py` / 浏览器直开 三种方式继续可用。

### 不起本地 HTTP 服务

网页应用要求「必须通过 http 服务打开」（`file://` 下 WebKit 会拦截子资源）。
桌面端没有沿用「再起一个本地服务」的思路，而是注册自定义资源协议
（`airwaves://`），由 App 自己从包内读文件交给 WebView。好处：

1. **不存在端口占用或冲突** —— 原 `start.sh` 里 8765–8769 的端口探测逻辑彻底不需要
2. **不监听任何 socket** —— 没有对外暴露的访问面
3. **资源来自只读 App 包** —— 天然只读

### 静态资源自动筛选

`assets/` 有 12 张图共 52 MB，但代码只引用其中 3 张。
`stage_web.py` 用正则从 CSS / JS 里提取实际引用路径，自动排除未引用的图，**省下 35.5 MB**。
网页应用若改了引用，重新打包会自动跟上，不需要改清单。

### 图标

上游素材是满幅方形图（无 alpha 通道），直接当 macOS 图标会得到硬边方角。
`make_icons.py` 会裁成 **macOS Big Sur+ 图标形状**：

- 圆角半径 = 边长 × 0.2237（Apple 图标网格规格）
- 圆角外透明
- 每个尺寸单独裁剪（避免小尺寸下圆角比例失真）
- 4 倍超采样绘制，边缘平滑抗锯齿

用「圆角矩形 + 幂次映射」逼近 Apple 的**连续曲率超椭圆（squircle）**，
而非普通圆弧圆角（后者在直线与圆弧接缝处有曲率突变，观感更硬）。
实测轮廓：圆角比 0.215、角点对角线内缩 0.068，与 macOS 原生规格吻合。

> 源图仅 256×256，放大到 512/1024 会偏软。想换高清图标：
> 把任意 ≥1024×1024 的方形 PNG 放到 `macos/Resources/icon-source.png`，
> 重跑 `build.sh` 即可，**无需改代码**。

### 偏好设置存在原生侧

`WKWebView` 在自定义 URL scheme 下的 `localStorage` 持久性在不同系统版本上表现不一致，
而「重启后设置还在」是硬要求。因此以原生 `UserDefaults` 为唯一真相，
前端通过 `WKScriptMessageHandler` 读写。没有原生桥时自动降级到 `localStorage`。

### 日志同步写

日志最需要它的时刻正是崩溃或异常退出的瞬间，异步缓冲会丢掉最后几行——
那恰恰是唯一有用的几行。本应用日志量极低，同步写不构成性能问题。

完整设计与实现细节见 [`docs/DESIGN.md`](docs/DESIGN.md)。

---

## 音频自检

验证「WKWebView 里的 Web Audio 真的能工作」这条最关键的假设：

```bash
AIRWAVES_AUTOTEST=1 "build/Air-Waves.app/Contents/MacOS/AirWaves"
```

启动 2.5 秒后派发一次合成键盘事件，走完网页应用的真实播放路径，
然后把 `AudioContext` 状态与左右声道载波写进日志：

```
[audio] AudioContext 已就绪（resume 成功）: state=running; sampleRate=44100;
        baseLatency=0.0029…; outputLatency=0.333…
自检：页面状态 {"view":"player","state":"playing","carrier":"L 200.0 / R 210.0 Hz", …}
```

左右声道载波差应等于当前 Δf（ALPHA 频段默认 10 Hz）。

---

## 验收自检

```bash
./scripts/verify.sh
```

33 项自动化检查，覆盖：产物结构、ad-hoc 签名有效性、冷启动、注入脚本生效、
音频链路（`AudioContext` running + 左右声道载波差 = Δf）、静态资源引用完整性、
退出清理与无残留进程、偏好落盘、零网络依赖、无密钥入库。

```
通过 33 · 失败 0 · 需人工确认 0
```

---

## 已知限制

| 限制 | 说明 |
|---|---|
| 图标是低清占位 | 上游 `.ico` 最高 256×256 且无 alpha，放大后偏软；换 `icon-source.png` 即可解决 |
| 仅 arm64 | 构建脚本写死 `arm64-apple-macos13.0`；Intel Mac 需改 target 或用 `universal` |
| 界面不跟随系统深浅色 | 网页应用是固定深色 CRT 主题（写死 `color-scheme: dark`）；「外观」设置影响的是窗口边框与原生控件 |
| 未做公证 | ad-hoc 签名。本机构建可直接打开；若经网盘/邮件传到别的 Mac，需 `xattr -dr com.apple.quarantine` |

### 无法签名时的本地绕过

本方案用 ad-hoc 签名（`codesign -s -`），**不需要 Apple 开发者账号**。

```bash
# 从网盘/压缩包传来的文件需要去掉隔离标记
xattr -dr com.apple.quarantine /Applications/Air-Waves.app

# 或：系统设置 → 隐私与安全性 → 找到拦截提示 → 点「仍要打开」

# 或：命令行直接启动（绕过 LaunchServices 检查）
/Applications/Air-Waves.app/Contents/MacOS/AirWaves

# 查看签名状态
codesign -dv /Applications/Air-Waves.app
```

---

## 故障排查

| 现象 | 排查 |
|---|---|
| 构建时报「找不到 Air-Waves 网页应用源码」 | 网页应用需与本仓库**并列**放置，或用 `AIRWAVES_WEB_ROOT` 指定 |
| 打开是白窗口 | 看日志；菜单「显示 → 重新载入（忽略缓存）」重试。首屏连续失败 2 次会显示带指引的错误页 |
| 没有声音 | 确认戴耳机、点了 PLAY、系统输出设备正确。日志搜 `[audio]`，应为 `state=running` |
| 背景图不显示 | `./scripts/build.sh --clean` 重建（会校验引用完整性） |
| 想彻底重置 | 菜单「帮助 → 重置为默认设置」，或 `defaults delete com.airwaves.private` |
| 编译报 `swiftc not found` | `xcode-select --install` |
| 图标生成失败 | `pip3 install --user Pillow` |
| 端口被占用 | **不会发生**——本方案不监听任何端口 |
| 想查进程 | `pgrep -fl Air-Waves`（退出后应为空） |

---

## 目录结构

```
air-waves-macos/
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
│   └── make_icons.py  图标生成（.ico → .icns，含圆角裁剪）
├── docs/DESIGN.md     完整设计文档
├── build/             构建产物（已 gitignore）
└── README.md          本文件
```

---

## 隐私与免责

- **零网络请求**：客户端不发起任何网络调用，网页应用代码内也无外部 URL
- **零遥测**：不收集、不上传任何数据
- **数据仅存本机**：日志与偏好都在你自己的 `~/Library` 下
- **无密钥**：整个项目不含任何 token、cookie、私钥、API key（`verify.sh` 会自动检查）

本工具仅用于放松与专注辅助，**非医疗设备**，不用于诊断、治疗或预防任何疾病。
双耳节拍的主观感受因人而异，如出现头晕、耳鸣或任何不适，请立即停止使用。

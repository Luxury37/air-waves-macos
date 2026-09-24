#!/usr/bin/env bash
# ============================================================================
#  Air-Waves 桌面端 — 构建脚本
#
#  产出：desktop/build/AirWaves.app   （可双击运行的 .app）
#
#  设计要点：
#    * 全部使用系统自带工具（swiftc / iconutil / codesign / hdiutil），
#      不依赖 Xcode 工程文件，不依赖 Homebrew，不依赖 Rust。
#    * App 是自包含的：静态资源复制进 Contents/Resources/web，
#      运行时不需要 Python、不需要联网、不占用任何端口。
#    * 原项目文件不做任何修改（见 stage_web.py）。
#
#  用法：
#      ./build.sh                  构建 .app
#      ./build.sh --clean          先清理再构建
#      ./build.sh --all-assets     把 assets/ 全部打包（默认只打包被引用的）
#      ./build.sh --install        构建后复制到 /Applications
#      ./build.sh --no-sign        跳过 ad-hoc 签名（默认会签名）
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------- 路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Air-Waves 网页应用的位置。
# 本仓库可以独立存在，因此不能假定自己是网页应用的子目录。
# 解析顺序：
#   1. 环境变量 AIRWAVES_WEB_ROOT
#   2. 与本仓库并列的 Air-Waves / Air-waves / air-waves / AirWaves
#   3. 上一层目录本身（本仓库位于 Air-Waves/desktop 时的布局）
find_web_root() {
  if [ -n "${AIRWAVES_WEB_ROOT:-}" ]; then
    printf '%s' "${AIRWAVES_WEB_ROOT}"
    return 0
  fi
  local parent candidate
  parent="$(cd "${DESKTOP_DIR}/.." && pwd)"
  for candidate in \
      "${parent}/Air-Waves" "${parent}/Air-waves" \
      "${parent}/air-waves" "${parent}/AirWaves" "${parent}"
  do
    if [ -f "${candidate}/index.html" ] && [ -f "${candidate}/app.js" ]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

PROJECT_ROOT="$(find_web_root || true)"

MACOS_DIR="${DESKTOP_DIR}/macos"
SRC_DIR="${MACOS_DIR}/Sources/AirWaves"
RES_DIR="${MACOS_DIR}/Resources"
BUILD_DIR="${DESKTOP_DIR}/build"
WEB_STAGE="${BUILD_DIR}/web"

APP_NAME="AirWaves"          # 可执行文件名（无空格，避免签名与路径问题）
APP_DISPLAY="Air-Waves"      # 显示名
BUNDLE_ID="com.airwaves.private"
APP_BUNDLE="${BUILD_DIR}/${APP_DISPLAY}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_BIN="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

# 部署目标：与 Info.plist 的 LSMinimumSystemVersion 保持一致
DEPLOY_TARGET="13.0"

# ---------------------------------------------------------------- 选项
CLEAN=0
ALL_ASSETS=0
DO_INSTALL=0
DO_SIGN=1
VERBOSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --clean)      CLEAN=1 ;;
    --all-assets) ALL_ASSETS=1 ;;
    --install)    DO_INSTALL=1 ;;
    --no-sign)    DO_SIGN=0 ;;
    --verbose|-v) VERBOSE=1 ;;
    -h|--help)    sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1（用 --help 查看用法）" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- 日志
step()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '\033[1;33m[警告]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 环境检查
step "检查构建环境"

# 网页应用源码是构建的必需输入：本仓库只含 macOS 外壳，
# index.html / app.js / audio.js / styles.css 与背景图都来自 Air-Waves 网页应用。
if [ -z "${PROJECT_ROOT}" ]; then
  cat >&2 <<'EOM'

[错误] 找不到 Air-Waves 网页应用的源码目录。

本仓库只包含 macOS 客户端外壳。构建时需要 Air-Waves 网页应用的
index.html / app.js / audio.js / styles.css 以及 assets/ 下的背景图。

请把网页应用放在以下任一位置：

  布局一（推荐，两个仓库并列）：
      ~/Documents/Air-Waves/          ← 网页应用
      ~/Documents/air-waves-macos/    ← 本仓库

  布局二（本仓库作为网页应用的子目录）：
      ~/Documents/Air-Waves/desktop/  ← 本仓库

  或者用环境变量显式指定：
      AIRWAVES_WEB_ROOT=/path/to/Air-Waves ./scripts/build.sh

如果还没有网页应用源码：
      git clone https://github.com/Luxury37/Air-Waves.git

EOM
  exit 1
fi

info "网页应用: ${PROJECT_ROOT}"

command -v swiftc >/dev/null 2>&1 || die "找不到 swiftc。请安装 Xcode 或 Command Line Tools：
    xcode-select --install"

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || true)"
[ -n "${SDK_PATH}" ] || die "找不到 macOS SDK。请确认 Xcode 已正确安装：
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

SWIFT_VERSION="$(swiftc --version 2>&1 | head -1)"
info "Swift: ${SWIFT_VERSION}"
info "SDK:   ${SDK_PATH}"

PYTHON_BIN=""
for candidate in python3 python; do
  if command -v "${candidate}" >/dev/null 2>&1; then PYTHON_BIN="${candidate}"; break; fi
done
[ -n "${PYTHON_BIN}" ] || die "找不到 python3（用于装配静态资源与生成图标）"
info "Python: $(${PYTHON_BIN} --version 2>&1)"

if ! "${PYTHON_BIN}" -c "import PIL" >/dev/null 2>&1; then
  warn "未检测到 Pillow，图标生成会失败。安装：pip3 install --user Pillow"
fi

# ---------------------------------------------------------------- 清理
if [ "${CLEAN}" = "1" ]; then
  step "清理构建目录"
  rm -rf "${BUILD_DIR}"
  info "已删除 ${BUILD_DIR}"
fi

mkdir -p "${BUILD_DIR}"

# ---------------------------------------------------------------- 版本信息
SOURCE_REV="unknown"
if git -C "${PROJECT_ROOT}" rev-parse --short HEAD >/dev/null 2>&1; then
  SOURCE_REV="$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD)"
  if ! git -C "${PROJECT_ROOT}" diff --quiet 2>/dev/null; then
    SOURCE_REV="${SOURCE_REV}-dirty"
  fi
fi
info "源码版本: ${SOURCE_REV}"

# ================================================================
#  1. 装配静态资源
# ================================================================
step "装配静态资源"

STAGE_ARGS=(--out "${WEB_STAGE}" --root "${PROJECT_ROOT}")
if [ "${ALL_ASSETS}" = "1" ]; then
  STAGE_ARGS+=(--all-assets)
fi
"${PYTHON_BIN}" "${SCRIPT_DIR}/stage_web.py" "${STAGE_ARGS[@]}"

# ================================================================
#  2. 生成图标
# ================================================================
step "生成应用图标"
if "${PYTHON_BIN}" "${SCRIPT_DIR}/make_icons.py"; then
  info "图标已生成"
else
  warn "图标生成失败，将使用系统默认图标继续构建"
fi

# ================================================================
#  3. 搭建 .app 骨架
# ================================================================
step "搭建 App Bundle"
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_BIN}" "${RESOURCES}"

cp "${RES_DIR}/Info.plist" "${CONTENTS}/Info.plist"
plutil -replace AirWavesSourceRevision -string "${SOURCE_REV}" "${CONTENTS}/Info.plist"

# 图标
if [ -f "${RES_DIR}/AppIcon.icns" ]; then
  cp "${RES_DIR}/AppIcon.icns" "${RESOURCES}/AppIcon.icns"
  info "已嵌入 AppIcon.icns"
else
  warn "缺少 AppIcon.icns，App 将显示为通用图标"
fi

# 静态资源
cp -R "${WEB_STAGE}" "${RESOURCES}/web"
info "静态资源已就位: $(find "${RESOURCES}/web" -type f | wc -l | tr -d ' ') 个文件"

# 使用说明（帮助菜单会打开它）
if [ -f "${PROJECT_ROOT}/START.md" ]; then
  cp "${PROJECT_ROOT}/START.md" "${RESOURCES}/使用说明.md"
fi
# 同时放一份客户端说明（独立仓库时即本仓库的 README）
if [ -f "${DESKTOP_DIR}/README.md" ]; then
  cp "${DESKTOP_DIR}/README.md" "${RESOURCES}/客户端说明.md"
fi
# 设计文档（独立仓库布局下存在；子目录布局下没有也不影响构建）
if [ -f "${DESKTOP_DIR}/docs/DESIGN.md" ]; then
  cp "${DESKTOP_DIR}/docs/DESIGN.md" "${RESOURCES}/设计说明.md"
fi

# 依赖库声明
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# ================================================================
#  4. 编译
# ================================================================
step "编译 Swift 源码"

SWIFT_SOURCES=()
while IFS= read -r -d '' f; do
  SWIFT_SOURCES+=("$f")
done < <(find "${SRC_DIR}" -name '*.swift' -print0 | sort -z)

[ ${#SWIFT_SOURCES[@]} -gt 0 ] || die "在 ${SRC_DIR} 下找不到任何 .swift 文件"

info "源文件 (${#SWIFT_SOURCES[@]} 个):"
for f in "${SWIFT_SOURCES[@]}"; do
  info "    $(basename "$f")"
done

SWIFT_FLAGS=(
  -O
  -target "arm64-apple-macos${DEPLOY_TARGET}"
  -sdk "${SDK_PATH}"
  -framework AppKit
  -framework SwiftUI
  -framework WebKit
  -parse-as-library
)
if [ "${VERBOSE}" = "1" ]; then
  SWIFT_FLAGS+=(-v)
fi

step "编译中（首次约 10-30 秒）"
if ! swiftc "${SWIFT_FLAGS[@]}" \
      -o "${MACOS_BIN}/${APP_NAME}" \
      "${SWIFT_SOURCES[@]}"; then
  die "编译失败。可加 -v 查看详细输出：
    ./build.sh -v"
fi

BIN_SIZE="$(du -h "${MACOS_BIN}/${APP_NAME}" | cut -f1)"
info "可执行文件: ${APP_NAME} (${BIN_SIZE})"

# ================================================================
#  5. ad-hoc 签名
# ================================================================
if [ "${DO_SIGN}" = "1" ]; then
  step "ad-hoc 签名"
  # 私人使用不需要 Apple 开发者账号（省掉 99 美元/年）。
  # ad-hoc 签名（-s -）足以让本机构建的应用正常启动，
  # 并且可以为后续「授予麦克风等权限」提供稳定的签名标识。
  if codesign --force --deep --sign - \
        --identifier "${BUNDLE_ID}" \
        "${APP_BUNDLE}" 2>"${BUILD_DIR}/codesign.log"; then
    info "已使用 ad-hoc 签名 (-)"
  else
    warn "签名失败，App 仍可运行。详情见 ${BUILD_DIR}/codesign.log"
    cat "${BUILD_DIR}/codesign.log" >&2 || true
  fi
else
  info "已跳过签名 (--no-sign)"
fi

# ================================================================
#  6. 校验
# ================================================================
step "校验产物"

FAILED=0
check() {
  if [ -e "$1" ]; then
    info "✓ $2"
  else
    warn "✗ 缺少 $2 ($1)"
    FAILED=1
  fi
}

check "${CONTENTS}/Info.plist"                        "Info.plist"
check "${MACOS_BIN}/${APP_NAME}"                      "可执行文件"
check "${RESOURCES}/web/index.html"                   "index.html"
check "${RESOURCES}/web/app.js"                       "app.js"
check "${RESOURCES}/web/audio.js"                     "audio.js"
check "${RESOURCES}/web/styles.css"                   "styles.css"
check "${RESOURCES}/web/assets/scene/scene-player.png" "播放页背景图"
check "${RESOURCES}/AppIcon.icns"                     "图标"

# plist 合法性
if plutil -lint "${CONTENTS}/Info.plist" >/dev/null 2>&1; then
  info "✓ Info.plist 格式合法"
else
  warn "✗ Info.plist 格式非法"
  FAILED=1
fi

# 关键：确认静态资源真的被解析到「被引用」这一层
if "${PYTHON_BIN}" - <<'PYCHECK' "${RESOURCES}/web"
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
css = (root / "styles.css").read_text(encoding="utf-8", errors="replace")
js = (root / "app.js").read_text(encoding="utf-8", errors="replace")
refs = set(m for m in re.findall(r"url\(\s*['\"]?([^'\")]+?)['\"]?\s*\)", css) if m.startswith("assets/"))
refs |= set(re.findall(r"['\"](assets/[^'\"]+)['\"]", js))
missing = [r for r in sorted(refs) if not (root / r).is_file()]
if missing:
    print("MISSING:" + ",".join(missing))
    sys.exit(1)
print(f"OK:{len(refs)}")
PYCHECK
then
  info "✓ 全部被引用的资源均已打包"
else
  warn "✗ 有被引用的资源未打包，运行时会缺失背景图"
  FAILED=1
fi

APP_SIZE="$(du -sh "${APP_BUNDLE}" | cut -f1)"

echo
if [ "${FAILED}" = "1" ]; then
  warn "校验未全部通过，请检查上面的警告"
else
  printf '\033[1;32m构建成功\033[0m\n'
fi
echo
info "产物:   ${APP_BUNDLE}"
info "体积:   ${APP_SIZE}"
info "运行:   open \"${APP_BUNDLE}\""
echo

# ================================================================
#  7. 可选安装
# ================================================================
if [ "${DO_INSTALL}" = "1" ]; then
  step "安装到 /Applications"
  DEST="/Applications/${APP_DISPLAY}.app"

  # 必须先「删除目标」再复制，不能直接往已有的 .app 上覆盖。
  #
  # 原因：ditto / cp -R 都是「合并」语义，只增不删。如果上一版构建里有
  # 后来被移除的文件（例如改名过的说明文档），它会残留在目标目录里，
  # 而该文件不在新构建的签名清单内 —— 结果就是
  #     codesign -v 报 "a sealed resource is missing or invalid"
  # App 仍能启动，但签名校验会失败，属于典型的环境脏数据问题。
  if [ -e "${DEST}" ]; then
    info "移除旧版本: ${DEST}"
    rm -rf "${DEST}"
  fi

  # 用 ditto 而非 cp -R：更可靠地保留扩展属性与签名信息
  if ditto "${APP_BUNDLE}" "${DEST}"; then
    info "已安装: ${DEST}"

    # 装完立刻自检签名，避免把「合并残留」这类问题留到运行时才发现
    if codesign -v "${DEST}" 2>/dev/null; then
      info "签名校验通过"
    else
      warn "安装后签名校验失败，通常是目标目录有残留文件。请执行："
      warn "    rm -rf \"${DEST}\" && ditto \"${APP_BUNDLE}\" \"${DEST}\""
    fi

    info "从启动台或 Finder 双击即可运行"
  else
    warn "安装失败（可能需要权限）。可直接使用 ${APP_BUNDLE}"
  fi
fi

exit 0

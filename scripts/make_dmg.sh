#!/usr/bin/env bash
# ============================================================================
#  Air-Waves 桌面端 — DMG 打包
#
#  产出：desktop/build/Air-Waves-<版本>.dmg
#        挂载后是一个普通的拖拽安装窗口（App + Applications 快捷方式）。
#
#  为什么用「可写 DMG → 转只读压缩」两步：
#    hdiutil create -srcfolder 一次性生成的是只读镜像，
#    没法在里面放指向 /Applications 的符号链接（拖拽安装的关键）。
#    所以先用 UDRW 建可写镜像、布置好内容，再转成 UDZO 压缩只读镜像。
#
#  用法：
#      ./make_dmg.sh                构建（如需要）+ 打包 DMG
#      ./make_dmg.sh --no-build     直接用现有 .app 打包
#      ./make_dmg.sh --open         打包完成后打开 DMG 所在目录
#      ./make_dmg.sh --mount        打包完成后挂载 DMG 以便检查
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${DESKTOP_DIR}/.." && pwd)"
BUILD_DIR="${DESKTOP_DIR}/build"
APP_DISPLAY="Air-Waves"
APP_BUNDLE="${BUILD_DIR}/${APP_DISPLAY}.app"

DO_BUILD=1
DO_OPEN=0
DO_MOUNT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) DO_BUILD=0 ;;
    --open)     DO_OPEN=1 ;;
    --mount)    DO_MOUNT=1 ;;
    -h|--help)  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1（用 --help 查看用法）" >&2; exit 2 ;;
  esac
  shift
done

step() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[警告]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 构建
if [ "${DO_BUILD}" = "1" ]; then
  step "构建 App"
  "${SCRIPT_DIR}/build.sh"
else
  [ -d "${APP_BUNDLE}" ] || die "找不到 ${APP_BUNDLE}，请先运行 ./build.sh"
fi

[ -d "${APP_BUNDLE}" ] || die "App 不存在：${APP_BUNDLE}"

# ---------------------------------------------------------------- 版本号
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || echo "1.0.0")"
REVISION="$(/usr/libexec/PlistBuddy -c 'Print :AirWavesSourceRevision' \
            "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || echo "unknown")"

DMG_NAME="${APP_DISPLAY}-${VERSION}.dmg"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
RW_DMG="${BUILD_DIR}/.${APP_DISPLAY}-rw.dmg"

info "版本: ${VERSION}（源码 ${REVISION}）"

# ---------------------------------------------------------------- 准备暂存目录
step "准备 DMG 内容"

STAGE_DIR="${BUILD_DIR}/dmg-stage"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"

# ditto 比 cp -R 更可靠地保留扩展属性与签名信息
ditto "${APP_BUNDLE}" "${STAGE_DIR}/${APP_DISPLAY}.app"
info "已复制 ${APP_DISPLAY}.app"

# 拖拽安装用的 Applications 快捷方式
ln -s /Applications "${STAGE_DIR}/Applications"
info "已创建 Applications 快捷方式"

# 附一份说明，避免日后忘了怎么绕过 Gatekeeper
cat > "${STAGE_DIR}/安装说明.txt" <<'README'
Air-Waves 私人 macOS 客户端 — 安装说明
========================================

【安装】
把左边的 Air-Waves.app 拖到右边的 Applications 文件夹即可。

【首次打开】
本 App 使用 ad-hoc 签名（没有 Apple 开发者签名），
在你自己这台机器上构建的话，双击通常可以直接打开。

如果系统提示「无法打开，因为 Apple 无法检查其是否包含恶意软件」，
在「系统设置 → 隐私与安全性」里点「仍要打开」即可。

如果 App 是通过网盘/邮件/压缩包传到这台机器的，文件会被打上
隔离标记，需要执行一次：

    xattr -dr com.apple.quarantine /Applications/Air-Waves.app

【这个 App 做什么】
基于 Web Audio API 的双耳节拍 / 等时节拍发生器，用于工作学习时的
专注与放松辅助。建议佩戴耳机，音量从 35% 起步。

【隐私】
零网络请求。不收集任何数据。配置只存在本机：
    ~/Library/Logs/AirWaves/         日志
    偏好设置由系统 UserDefaults 保存

【免责】
本工具仅用于放松与专注辅助，非医疗设备，
不用于诊断、治疗或预防任何疾病。如感不适请立即停止。

【原始项目】
上游 Air-Waves 网页应用未附带许可证（默认保留所有权利）。
本客户端为个人本地构建版本，仅供个人使用，请勿再分发。
README

# ---------------------------------------------------------------- 生成 DMG
step "生成磁盘映像"

rm -f "${DMG_PATH}" "${RW_DMG}"

# 1) 可写镜像（容量留出余量）
APP_SIZE_KB="$(du -sk "${STAGE_DIR}" | cut -f1)"
RW_SIZE_KB=$(( APP_SIZE_KB + 20480 ))   # +20MB 余量

hdiutil create \
  -srcfolder "${STAGE_DIR}" \
  -volname "${APP_DISPLAY}" \
  -fs HFS+ \
  -format UDRW \
  -size "${RW_SIZE_KB}k" \
  -ov \
  "${RW_DMG}" >/dev/null

info "已创建可写镜像 ($(( RW_SIZE_KB / 1024 )) MB)"

# 2) 转成压缩只读镜像
hdiutil convert "${RW_DMG}" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "${DMG_PATH}" >/dev/null

rm -f "${RW_DMG}"
rm -rf "${STAGE_DIR}"

[ -f "${DMG_PATH}" ] || die "DMG 生成失败"

# ---------------------------------------------------------------- 校验
step "校验"

if hdiutil verify "${DMG_PATH}" >/dev/null 2>&1; then
  info "✓ 映像完整性校验通过"
else
  warn "映像校验未通过（通常仍可使用，但建议重新打包）"
fi

DMG_SIZE="$(du -h "${DMG_PATH}" | cut -f1)"
APP_SIZE="$(du -sh "${APP_BUNDLE}" | cut -f1)"

echo
printf '\033[1;32mDMG 打包完成\033[0m\n'
echo
info "产物:   ${DMG_PATH}"
info "体积:   ${DMG_SIZE}（App 解压后 ${APP_SIZE}）"
info "挂载:   open \"${DMG_PATH}\""
echo

# ---------------------------------------------------------------- 可选动作
if [ "${DO_MOUNT}" = "1" ]; then
  step "挂载以便检查"
  MOUNT_POINT="$(hdiutil attach "${DMG_PATH}" -nobrowse -readonly \
                  | grep -o '/Volumes/.*' | head -1)"
  info "已挂载到 ${MOUNT_POINT}"
  info "卸载：hdiutil detach \"${MOUNT_POINT}\""
  open "${MOUNT_POINT}"
fi

if [ "${DO_OPEN}" = "1" ]; then
  open "$(dirname "${DMG_PATH}")"
fi

exit 0

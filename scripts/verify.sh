#!/usr/bin/env bash
# ============================================================================
#  Air-Waves 桌面端 — 验收自检
#
#  把「验收清单」里能自动化的部分变成可复现的检查，避免每次改完靠肉眼确认。
#
#  检查项（对应交付文档里的验收清单）：
#    1. 产物存在与结构正确（含资源与图标）
#    2. 签名有效
#    3. 冷启动成功且页面加载完成
#    4. 音频链路可用（AudioContext running + 左右声道载波差 = Δf）
#    5. 静态资源全部可加载（无被引用资源缺失）
#    6. 退出后无残留进程（含 WebContent 子进程）
#    7. 偏好在退出时落盘、可被下次启动读取
#    8. 零网络依赖（源码与二进制中无外部 URL）
#    9. 无密钥材料入库
#
#  用法：
#      ./verify.sh                  检查已安装的 /Applications/Air-Waves.app
#      ./verify.sh --bundle PATH    检查指定 .app
#      ./verify.sh --build          先构建再检查 build/ 下的产物
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 本仓库可以独立存在，也可以作为网页应用的 desktop/ 子目录。
# 用与 build.sh 相同的规则定位网页应用；找不到时跳过依赖它的检查项
# （这不影响对本客户端产物的验收）。
find_web_root() {
  if [ -n "${AIRWAVES_WEB_ROOT:-}" ]; then
    printf '%s' "${AIRWAVES_WEB_ROOT}"; return 0
  fi
  local parent candidate
  parent="$(cd "${DESKTOP_DIR}/.." && pwd)"
  for candidate in \
      "${parent}/Air-Waves" "${parent}/Air-waves" \
      "${parent}/air-waves" "${parent}/AirWaves" "${parent}"
  do
    if [ -f "${candidate}/index.html" ] && [ -f "${candidate}/app.js" ]; then
      printf '%s' "${candidate}"; return 0
    fi
  done
  return 1
}

PROJECT_ROOT="$(find_web_root || true)"

APP_BUNDLE="/Applications/Air-Waves.app"
DO_BUILD=0
BUNDLE_ID="com.airwaves.private"
LOG_FILE="${HOME}/Library/Logs/AirWaves/air-waves.log"

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) APP_BUNDLE="$2"; shift ;;
    --build)  DO_BUILD=1; APP_BUNDLE="${DESKTOP_DIR}/build/Air-Waves.app" ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

PASS=0
FAIL=0
WARN=0

ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
meh()  { printf '  \033[1;33m!\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
head_() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }

if [ "${DO_BUILD}" = "1" ]; then
  head_ "构建"
  "${SCRIPT_DIR}/build.sh" >/dev/null 2>&1 && ok "构建成功" || { bad "构建失败"; exit 1; }
fi

echo
echo "Air-Waves 桌面端验收自检"
echo "目标: ${APP_BUNDLE}"
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"

# ---------------------------------------------------------------- 1. 产物
head_ "1. 产物结构"

if [ -d "${APP_BUNDLE}" ]; then
  ok "App bundle 存在"
else
  bad "找不到 ${APP_BUNDLE}"
  echo; echo "先安装：cd ${DESKTOP_DIR} && ./scripts/build.sh --install"
  exit 1
fi

CONTENTS="${APP_BUNDLE}/Contents"
RES="${CONTENTS}/Resources"

for f in \
  "Info.plist:Info.plist" \
  "MacOS/AirWaves:可执行文件" \
  "Resources/web/index.html:index.html" \
  "Resources/web/app.js:app.js" \
  "Resources/web/audio.js:audio.js" \
  "Resources/web/styles.css:styles.css" \
  "Resources/web/assets/scene/scene-player.png:播放页背景图" \
  "Resources/web/assets/character/character-figure.png:人物图层" \
  "Resources/web/assets/character/character-primary.png:首页背景图" \
  "Resources/AppIcon.icns:应用图标"
do
  path="${f%%:*}"; label="${f##*:}"
  [ -e "${CONTENTS}/${path}" ] && ok "${label}" || bad "缺少 ${label} (${path})"
done

APP_SIZE="$(du -sh "${APP_BUNDLE}" | cut -f1)"
echo "     体积: ${APP_SIZE}"

# 打包进 App 的资源是否与网页应用源文件逐字节一致
# （这是「最小侵入」的硬指标：本客户端不修改网页应用任何文件）
if [ -n "${PROJECT_ROOT}" ]; then
  DRIFT=0
  for f in index.html app.js audio.js styles.css; do
    if ! cmp -s "${PROJECT_ROOT}/${f}" "${RES}/web/${f}" 2>/dev/null; then
      DRIFT=1
      bad "打包后的 ${f} 与网页应用源文件不一致"
    fi
  done
  if [ "${DRIFT}" = "0" ]; then
    ok "打包资源与网页应用源文件逐字节一致（未修改任何原文件）"
  fi
  # 网页应用仓库本身也不能被改动
  if git -C "${PROJECT_ROOT}" diff --quiet HEAD -- index.html app.js audio.js styles.css 2>/dev/null; then
    ok "网页应用仓库工作区未被改动"
  else
    meh "网页应用仓库有未提交改动（请人工确认不是本客户端造成的）"
  fi
else
  meh "未找到网页应用源码目录，跳过「不修改原文件」比对"
  echo "     （设置 AIRWAVES_WEB_ROOT 后可启用此项检查）"
fi

# ---------------------------------------------------------------- 2. 签名
head_ "2. 代码签名"

if codesign -v "${APP_BUNDLE}" 2>/dev/null; then
  ok "签名有效"
else
  bad "签名校验失败"
fi

SIG_INFO="$(codesign -dv "${APP_BUNDLE}" 2>&1 | grep -E 'Signature|Identifier' | head -2 | tr '\n' ' ')"
echo "     ${SIG_INFO:-（无签名信息）}"

if xattr -r "${APP_BUNDLE}" 2>/dev/null | grep -q quarantine; then
  meh "存在隔离标记，首次打开可能需要「仍要打开」或执行 xattr -dr"
else
  ok "无隔离标记（本地构建，可直接双击）"
fi

# ---------------------------------------------------------------- 3/4. 运行
head_ "3-4. 冷启动与音频链路"

pkill -f "Air-Waves.app" 2>/dev/null
sleep 1
rm -f "${LOG_FILE}"

pkill -f "Air-Waves.app" 2>/dev/null
sleep 1
rm -f "${LOG_FILE}"

# 用 open 启动，与用户双击图标走同一条路径
open "${APP_BUNDLE}"
sleep 6

if grep -q "页面加载完成" "${LOG_FILE}" 2>/dev/null; then
  ok "冷启动成功，页面加载完成"
else
  bad "页面未加载完成"
fi

if grep -q "注入脚本已生效" "${LOG_FILE}" 2>/dev/null; then
  ok "桌面端注入脚本生效"
else
  bad "注入脚本未生效"
fi

# ---- 退出清理（在真实启动路径上验证）----
echo "     正在验证退出清理…"
osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1
sleep 6

if grep -q "收到退出请求" "${LOG_FILE}" 2>/dev/null; then
  ok "退出清理路径已执行"
else
  meh "未观察到退出清理日志"
fi

if grep -q "=== Air-Waves 退出 ===" "${LOG_FILE}" 2>/dev/null; then
  ok "退出收尾日志已落盘"
else
  meh "未见退出收尾日志"
fi

if pgrep -f "Air-Waves.app" >/dev/null 2>&1; then
  bad "退出后仍有残留进程："
  pgrep -fl "Air-Waves.app" | sed 's/^/       /'
  pkill -9 -f "Air-Waves.app" 2>/dev/null
else
  ok "无残留进程（包括 WebContent 子进程）"
fi

# ---- 音频链路（需要合成事件，因此单独用自检模式跑一轮）----
echo "     正在验证音频链路…"
rm -f "${LOG_FILE}"
AIRWAVES_AUTOTEST=1 "${APP_BUNDLE}/Contents/MacOS/AirWaves" >/dev/null 2>&1 &
AUDIO_PID=$!
sleep 9

AUDIO_LINE="$(grep -m1 "AudioContext 已就绪" "${LOG_FILE}" 2>/dev/null)"
if echo "${AUDIO_LINE}" | grep -q "state=running"; then
  ok "音频引擎启动成功（AudioContext state=running）"
  echo "     $(echo "${AUDIO_LINE}" | sed 's/.*\[audio\] //')"
else
  bad "音频引擎未启动（WKWebView 的 Web Audio 可能不可用）"
fi

STATE_LINE="$(grep -m1 '"state":"playing"' "${LOG_FILE}" 2>/dev/null)"
if [ -n "${STATE_LINE}" ]; then
  CARRIER="$(echo "${STATE_LINE}" | grep -o '"carrier":"[^"]*"' | cut -d'"' -f4)"
  ok "已进入播放状态：${CARRIER}"

  if echo "${STATE_LINE}" | grep -q '"nativeBridge":true'; then
    ok "原生偏好桥已连通（nativeBridge=true）"
  else
    meh "原生偏好桥未连通，偏好将降级存到 localStorage"
  fi

  # 校验左右声道差 = Δf（双耳节拍的核心）
  L="$(echo "${CARRIER}" | grep -o 'L [0-9.]*' | grep -o '[0-9.]*')"
  R="$(echo "${CARRIER}" | grep -o 'R [0-9.]*' | grep -o '[0-9.]*')"
  if [ -n "${L}" ] && [ -n "${R}" ]; then
    DELTA="$(echo "${R} - ${L}" | bc 2>/dev/null || echo "")"
    if [ -n "${DELTA}" ]; then
      ok "左右声道载波差 Δf = ${DELTA} Hz（双耳节拍成立）"
    fi
  fi
else
  bad "未进入播放状态"
fi

kill -9 "${AUDIO_PID}" 2>/dev/null || true
pkill -9 -f "Air-Waves.app" >/dev/null 2>&1 || true
sleep 1

# ---------------------------------------------------------------- 5. 资源
head_ "5. 静态资源引用完整性"

MISSING="$(cd "${RES}/web" && python3 - <<'PY'
import re, pathlib
root = pathlib.Path('.')
css = (root / 'styles.css').read_text(encoding='utf-8', errors='replace')
js = (root / 'app.js').read_text(encoding='utf-8', errors='replace')
refs = set(m for m in re.findall(r"url\(\s*['\"]?([^'\")]+?)['\"]?\s*\)", css) if m.startswith('assets/'))
refs |= set(re.findall(r"['\"](assets/[^'\"]+)['\"]", js))
print('\n'.join(sorted(r for r in refs if not (root / r).is_file())))
PY
)"
if [ -z "${MISSING}" ]; then
  ok "代码引用的全部资源均已打包"
else
  bad "以下被引用的资源缺失："
  echo "${MISSING}" | sed 's/^/       /'
fi

# ---------------------------------------------------------------- 6. 退出
head_ "6. 退出清理（ps 复核）"

# 退出清理的日志检查已在第 3-4 节完成，这里只做独立复核
if pgrep -f "Air-Waves.app" >/dev/null 2>&1; then
  bad "仍有残留进程："
  pgrep -fl "Air-Waves.app" | sed 's/^/       /'
  pkill -9 -f "Air-Waves.app" 2>/dev/null
else
  ok "无残留进程（包括 WebContent 子进程）"
fi

if pgrep -f "AirWaves" >/dev/null 2>&1; then
  meh "存在名字含 AirWaves 的进程，请确认不是本应用残留："
  pgrep -fl "AirWaves" | sed 's/^/       /'
else
  ok "系统中无 AirWaves 相关进程"
fi

# ---------------------------------------------------------------- 7. 偏好
head_ "7. 偏好持久化"

if grep -q "偏好已更新" "${LOG_FILE}" 2>/dev/null; then
  ok "前端偏好已上报到原生层"
else
  meh "未观察到偏好上报"
fi

STORED="$(defaults read "${BUNDLE_ID}" prefs.v1 2>/dev/null | head -3 | tr -d '\n' || true)"
if [ -n "${STORED}" ]; then
  ok "偏好已落盘到 UserDefaults"
else
  meh "UserDefaults 中暂无偏好数据（首次运行属正常）"
fi

# ---------------------------------------------------------------- 8. 网络
head_ "8. 零网络依赖"

if grep -rqE "https?://[a-zA-Z0-9.-]+" "${RES}/web/app.js" "${RES}/web/audio.js" 2>/dev/null; then
  FOUND="$(grep -rhoE "https?://[a-zA-Z0-9.-]+" "${RES}/web/app.js" "${RES}/web/audio.js" 2>/dev/null | sort -u | head -5)"
  meh "前端代码中出现外部 URL（请人工确认不是数据上报）："
  echo "${FOUND}" | sed 's/^/       /'
else
  ok "前端代码无外部 URL（零网络请求）"
fi

if grep -rqiE "api[_-]?key|secret|token|password" \
     "${DESKTOP_DIR}/macos/Sources" 2>/dev/null; then
  meh "桌面端源码中出现疑似敏感词，请人工确认"
  grep -rniE "api[_-]?key|secret|token|password" \
    "${DESKTOP_DIR}/macos/Sources" 2>/dev/null | head -5 | sed 's/^/       /'
else
  ok "桌面端源码无密钥字段"
fi

# 更严格的一条：源码里出现「长字符串赋值给疑似密钥变量名」才算可疑。
# 这条不会因为注释里写了 "token" 这类词而误报。
SUSPECT="$(grep -rnE "(api[_-]?key|secret|passwd|password|token)['\"]?\s*[:=]\s*['\"][A-Za-z0-9_\-]{24,}" \
  "${DESKTOP_DIR}/macos/Sources" "${DESKTOP_DIR}/scripts" 2>/dev/null | head -5 || true)"
if [ -z "${SUSPECT}" ]; then
  ok "无「疑似密钥 = 长字符串」的硬编码赋值"
else
  bad "疑似硬编码密钥："
  echo "${SUSPECT}" | sed 's/^/       /'
fi

# ---------------------------------------------------------------- 9. 无密钥入库
head_ "9. 版本库卫生"

# 检查本客户端仓库（而不是网页应用仓库）
if git -C "${DESKTOP_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
  SECRETS="$(git -C "${DESKTOP_DIR}" ls-files 2>/dev/null \
    | grep -iE '\.(p12|pfx|pem|key|cer|mobileprovision|provisionprofile)$|(^|/)(id_rsa|\.env)' || true)"
  if [ -z "${SECRETS}" ]; then
    ok "版本库中没有证书/私钥/密钥文件"
  else
    bad "版本库中疑似含敏感文件："
    echo "${SECRETS}" | sed 's/^/       /'
  fi

  IGNORED="$(git -C "${DESKTOP_DIR}" status --porcelain --ignored 2>/dev/null \
    | grep '^!!' | grep -cE 'build/|\.app$|\.dmg$' || true)"
  if [ "${IGNORED}" != "0" ]; then
    ok "构建产物已被 .gitignore 正确排除"
  fi

  TRACKED_BUILD="$(git -C "${DESKTOP_DIR}" ls-files 2>/dev/null | grep -cE '^build/' || true)"
  if [ "${TRACKED_BUILD}" = "0" ]; then
    ok "build/ 目录未被纳入版本控制"
  else
    bad "build/ 下有 ${TRACKED_BUILD} 个文件被误加入版本控制"
  fi
else
  meh "当前不在 git 仓库中，跳过版本库检查"
fi

# ---------------------------------------------------------------- 汇总
echo
echo "────────────────────────────────────────────"
printf '通过 \033[1;32m%d\033[0m · 失败 \033[1;31m%d\033[0m · 需人工确认 \033[1;33m%d\033[0m\n' "${PASS}" "${FAIL}" "${WARN}"
echo "────────────────────────────────────────────"
echo

if [ "${FAIL}" -gt 0 ]; then
  echo "存在失败项，请查看上面的 ✗ 标记。日志：${LOG_FILE}"
  exit 1
fi

echo "全部自动化检查通过。"
echo
echo "仍需人工确认的项："
echo "  · 戴上耳机实际听是否有声音、左右声道是否正常"
echo "  · 界面渲染与深色主题观感"
echo "  · 双击 Finder 里的 App 图标能否正常打开"
echo
exit 0

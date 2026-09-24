#!/usr/bin/env bash
# ============================================================================
#  Air-Waves 桌面端 — 开发运行脚本
#
#  做三件事：退出正在运行的实例 → 重新构建 → 启动并跟踪日志。
#  改完 Swift 或前端代码后跑这一条就够了。
#
#  用法：
#      ./dev.sh                 构建并运行，并 tail 日志
#      ./dev.sh --no-log        构建并运行，不 tail 日志
#      ./dev.sh --clean         先清理再构建（改了资源/图标时用）
#      ./dev.sh --all-assets    打包 assets/ 全部图片（默认只打包被引用的）
#      ./dev.sh --test          以自检模式运行（自动触发播放并记录音频状态）
#      ./dev.sh --stdout        前台运行，直接看 stderr（Ctrl+C 退出）
#      ./dev.sh --kill          只退出正在运行的实例
#      ./dev.sh --log           只跟踪日志
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_BUNDLE="${DESKTOP_DIR}/build/Air-Waves.app"
BINARY="${APP_BUNDLE}/Contents/MacOS/AirWaves"
LOG_FILE="${HOME}/Library/Logs/AirWaves/air-waves.log"
BUNDLE_ID="com.airwaves.private"

step() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[警告]\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------- 退出实例
kill_running() {
  local found=0

  # 优先用优雅退出，让 App 走完清理路径（这正是我们要验证的行为）
  if pgrep -f "${APP_BUNDLE}" >/dev/null 2>&1; then
    found=1
    step "正在退出已运行的实例（走正常退出流程）"
    osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true

    # 最多等 5 秒
    for _ in $(seq 1 25); do
      pgrep -f "${APP_BUNDLE}" >/dev/null 2>&1 || break
      sleep 0.2
    done
  fi

  # 仍不退出则强制结束（说明清理路径卡住了，值得注意）
  if pgrep -f "${APP_BUNDLE}" >/dev/null 2>&1; then
    warn "优雅退出超时，强制结束进程"
    pkill -f "${APP_BUNDLE}" 2>/dev/null || true
    sleep 0.5
  fi

  if [ "${found}" = "1" ]; then
    if pgrep -f "${APP_BUNDLE}" >/dev/null 2>&1; then
      warn "仍有残留进程！请手动检查：pgrep -fl Air-Waves"
    else
      info "已干净退出"
    fi
  fi
}

# ---------------------------------------------------------------- 参数
MODE="normal"
BUILD_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --kill)       kill_running; exit 0 ;;
    --log)        exec tail -f "${LOG_FILE}" ;;
    --no-log)     MODE="no-log" ;;
    --test)       MODE="test" ;;
    --stdout)     MODE="stdout" ;;
    --clean)      BUILD_ARGS+=(--clean) ;;
    --all-assets) BUILD_ARGS+=(--all-assets) ;;
    --verbose|-v) BUILD_ARGS+=(--verbose) ;;
    -h|--help)    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1（用 --help 查看用法）" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- 构建
kill_running

step "构建"
"${SCRIPT_DIR}/build.sh" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}

[ -x "${BINARY}" ] || { warn "找不到可执行文件 ${BINARY}"; exit 1; }

# ---------------------------------------------------------------- 运行
step "启动 ${APP_BUNDLE}"

case "${MODE}" in
  stdout)
    info "前台运行，Ctrl+C 退出"
    info "日志同时写入 ${LOG_FILE}"
    echo
    AIRWAVES_AUTOTEST="${AIRWAVES_AUTOTEST:-}" "${BINARY}"
    exit 0
    ;;

  test)
    info "自检模式：启动后会自动触发一次播放并记录音频状态"
    info "日志：${LOG_FILE}"
    echo
    : > "${LOG_FILE}" 2>/dev/null || true
    AIRWAVES_AUTOTEST=1 AIRWAVES_AUTOTEST_DELAY="${AIRWAVES_AUTOTEST_DELAY:-2.5}" \
      "${BINARY}" > /tmp/airwaves-dev-stdout.log 2>&1 &
    sleep 9
    echo "──────────────── 日志 ────────────────"
    cat "${LOG_FILE}"
    echo "──────────────────────────────────────"
    echo
    info "关注这两行来确认音频正常："
    info "  · AudioContext 已就绪（resume 成功）: state=running"
    info "  · carrier: L … / R …  （左右声道应相差 Δf）"
    exit 0
    ;;

  *)
    open "${APP_BUNDLE}"
    sleep 1.5
    if pgrep -f "${APP_BUNDLE}" >/dev/null 2>&1; then
      info "已启动"
    else
      warn "启动失败，请查看日志：${LOG_FILE}"
      exit 1
    fi
    ;;
esac

# ---------------------------------------------------------------- 跟踪日志
if [ "${MODE}" = "normal" ]; then
  echo
  info "按 Ctrl+C 停止跟踪（不会退出 App）"
  info "退出 App：./dev.sh --kill"
  echo
  tail -f "${LOG_FILE}"
fi

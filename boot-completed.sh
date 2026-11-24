#!/system/bin/sh
# =====================================================================
#  boot-completed.sh —— sys.boot_completed=1 之后由 KernelSU 执行
#
#  职责：
#    1. 在开机完成的第一时间把 Shizuku 拉起来（不用 service.sh 轮询 getprop）
#    2. 确认常驻守护在跑，不在就补一个
#  （Magisk 不支持这个脚本，service.sh 自身也有兜底，不影响使用）
# =====================================================================

case "$0" in
  */*) MODDIR=${0%/*} ;;
  *)   MODDIR=${PWD:-/data/adb/modules/shizuku_keep}
       [ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/shizuku_keep ;;
esac

CONF="$MODDIR/config.conf"
LOG="$MODDIR/keep.log"

ALWAYS_ON=1
AUTO_WATCH=1
WATCH_APPS=""
EXCLUDE_APPS=""

# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

# shellcheck disable=SC1091
. "$MODDIR/common.sh"

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >>"$LOG"; }

# 守护没在跑就补一个（出现过 service.sh 因残留锁提前退出的情况）
ensure_guard() {
  [ -n "$(guard_pid)" ] && return 0
  log "boot-completed：守护未运行，重新拉起"
  ( cd /data/local/tmp && setsid sh "$MODDIR/service.sh" >/dev/null 2>&1 </dev/null ) &
}

# boot_completed 之后 ActivityManager 有时还没完全起好，稍等一下
sleep 3

# 按需模式：不主动拉起 Shizuku，但守护必须在（它负责按需唤醒）
if [ "$ALWAYS_ON" != "1" ]; then
  log "boot-completed：按需唤醒模式，跳过拉起"
  ensure_guard
  exit 0
fi

if shizuku_alive; then
  log "boot-completed：服务已在运行（pid $(shizuku_pids | awk '{print $1}')）"
  ensure_guard
  exit 0
fi

log "boot-completed：拉起 Shizuku"
if ! start_shizuku "开机完成"; then
  log "boot-completed：拉起失败，交给守护循环重试"
fi

ensure_guard

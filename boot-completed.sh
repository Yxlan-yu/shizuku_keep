#!/system/bin/sh
# =====================================================================
#  boot-completed.sh —— sys.boot_completed=1 之后由 KernelSU 执行
#
#  职责只有一件事：在开机完成的第一时间把 Shizuku 拉起来。
#  这样 service.sh 不需要 3 秒一轮去轮询 getprop。
#  （Magisk 不支持这个脚本，service.sh 里有同样的兜底逻辑，不影响使用）
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

# boot_completed 之后 ActivityManager 有时还没完全起好，稍等一下
sleep 3

if [ "$ALWAYS_ON" != "1" ]; then
  log "boot-completed：按需唤醒模式，跳过拉起"
  exit 0
fi

if shizuku_alive; then
  log "boot-completed：服务已在运行（pid $(shizuku_pids | awk '{print $1}')）"
  exit 0
fi

log "boot-completed：拉起 Shizuku"
if ! start_shizuku "开机完成"; then
  log "boot-completed：拉起失败，交给守护循环重试"
fi

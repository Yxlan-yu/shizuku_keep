#!/system/bin/sh
# =====================================================================
#  Shizuku 常驻守护 (KernelSU 模块)
#
#  ALWAYS_ON=1（默认）：开机把 Shizuku 以 root 拉起，之后常驻守护，
#                        进程一消失就被补回来 —— 相当于"永久开启授权"。
#                        ★ 这个模式下是全局生效的，任何用 Shizuku 的
#                          应用都能拿到授权，不需要维护任何列表。
#  ALWAYS_ON=0        ：仅当"目标应用"在前台时才拉起。目标应用来源：
#                        1) config.conf 里的 WATCH_APPS（手工列表）
#                        2) AUTO_WATCH=1 时自动扫描到的、声明了 Shizuku
#                           权限的所有应用（新装的会自动补进来）
#
#  拉起方式：调用 Shizuku 自带的启动器 libshizuku.so
#    它自己会切 mount namespace / cgroup、定位 base.apk，再以 root
#    启动 shizuku_server。唯一要注意的坑（已踩过）：
#      启动器日志必须写在 /data/local/tmp，写进本模块目录会让它内部
#      调用的 pm 取不到包路径，报 fatal: can't get path of manager。
#    setsid 是安全的，可放心用来脱离会话。
# =====================================================================

case "$0" in
  */*) MODDIR=${0%/*} ;;
  *)   MODDIR=/data/adb/modules/shizuku_keep ;;
esac

LOG="$MODDIR/keep.log"
CONF="$MODDIR/config.conf"
LOCK="/data/adb/shizuku_keep.lock"
AUTOLIST=/data/adb/shizuku_keep.auto

ALWAYS_ON=1
WATCH_APPS=""
AUTO_WATCH=1
EXCLUDE_APPS=""
POLL_DEAD=6
POLL_ALIVE=12
AUTO_RESCAN=1800

# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

# 公共函数（定位启动器 / 存活判断 / 前台探测），配置先读，包名才生效
# shellcheck disable=SC1091
. "$MODDIR/common.sh"

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >>"$LOG"; }

# 扫描所有"真正声明了 Shizuku 权限"的应用（仅第三方包），写入 $AUTOLIST
# 判定依据：dumpsys package 里出现 moe.shizuku.manager.permission
# 不能用裸 grep shizuku —— dumpsys 输出里的最近任务列表会把所有包都带上。
scan_auto() {
  tmp="$AUTOLIST.tmp"
  : >"$tmp"
  pm list packages -3 2>/dev/null | sed 's/^package://' | while read -r p; do
    [ -z "$p" ] && continue
    [ "$p" = "$SHIZUKU_PKG" ] && continue
    if dumpsys package "$p" 2>/dev/null | grep -q 'moe\.shizuku\.manager\.permission'; then
      echo "$p" >>"$tmp"
    fi
  done
  for w in $WATCH_APPS; do echo "$w" >>"$tmp"; done
  # 用户排除掉的不要（下次扫描不加回来）
  for e in $EXCLUDE_APPS; do
    [ -z "$e" ] && continue
    grep -vx "$e" "$tmp" >"$tmp.f" 2>/dev/null
    [ -f "$tmp.f" ] && mv -f "$tmp.f" "$tmp" 2>/dev/null
  done
  sort -u "$tmp" 2>/dev/null | grep -v '^[[:space:]]*$' >"$AUTOLIST.new" 2>/dev/null
  mv -f "$AUTOLIST.new" "$AUTOLIST" 2>/dev/null
  rm -f "$tmp"
  log "自动发现完成：$(wc -l <"$AUTOLIST" 2>/dev/null) 个应用在用 Shizuku"
}

# 供 watch.sh auto 调用：只扫描，不进守护循环
if [ "$1" = "--scan-only" ]; then
  scan_auto
  exit 0
fi

# ---- 自我脱离会话（防止被启动者的进程组回收）----
if [ -z "$SHIZUKU_KEEP_DETACHED" ] && command -v setsid >/dev/null 2>&1; then
  SHIZUKU_KEEP_DETACHED=1 setsid sh "$MODDIR/service.sh" >/dev/null 2>&1 </dev/null &
  exit 0
fi

# ---- 单实例锁（mkdir 原子操作，避免开机瞬间双实例）----
if ! mkdir "$LOCK" 2>/dev/null; then
  OLD=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$OLD" ] && [ -d "/proc/$OLD" ]; then
    exit 0
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || exit 0
fi
echo $$ >"$LOCK/pid"
rm -f /data/adb/shizuku_keep.pid

trim_log() {
  [ -f "$LOG" ] || return 0
  sz=$(wc -c <"$LOG" 2>/dev/null)
  [ -n "$sz" ] && [ "$sz" -gt 81920 ] && : >"$LOG"
  return 0
}

alive() { shizuku_alive; }

is_watched() {
  p="$1"
  [ -z "$p" ] && return 1
  for w in $WATCH_APPS; do
    [ "$p" = "$w" ] && return 0
  done
  if [ "$AUTO_WATCH" = "1" ] && [ -f "$AUTOLIST" ]; then
    grep -qx "$p" "$AUTOLIST" 2>/dev/null && return 0
  fi
  return 1
}

start_server() {
  log "拉起 Shizuku（缘由: $1）"
  if ! start_shizuku "$1"; then
    log "拉起失败：找不到启动器（Shizuku 未安装或 APK 内无 native 库）"
    return 1
  fi
  return 0
}

log "=== shizuku_keep 启动 (ALWAYS_ON=$ALWAYS_ON, AUTO_WATCH=$AUTO_WATCH, 手工列表: ${WATCH_APPS:-无}) ==="

# 等开机完成
# KernelSU 会用 boot-completed.sh 在最准的时机先拉一次，这里主要照顾
# Magisk / 没有 boot-completed 支持的环境；限时 5 分钟，绝不死等。
n=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 3
  n=$((n + 1))
  [ "$n" -gt 100 ] && break
done
sleep 6

# 兜底首次拉起（真被 boot-completed.sh 拉过了就跳过）
if [ "$ALWAYS_ON" = "1" ] && ! alive; then
  start_server "开机"
  sleep 12
fi

LAST_FG=""
LAST_SCAN=0

while true; do
  # 热加载配置：改完 config.conf 立即生效，不用重启守护
  # shellcheck disable=SC1090
  [ -f "$CONF" ] && . "$CONF"

  NOW=$(date +%s)

  if alive; then
    sleep "${POLL_ALIVE:-12}"
    trim_log
    continue
  fi

  if [ "$ALWAYS_ON" = "1" ]; then
    start_server "进程消失"
    sleep 12
    continue
  fi

  # ---- 按需模式 ----
  # 定期重扫，保证新装的 Shizuku 应用自动纳入
  if [ "$AUTO_WATCH" = "1" ] && [ $((NOW - LAST_SCAN)) -ge "${AUTO_RESCAN:-1800}" ]; then
    LAST_SCAN=$NOW
    ( scan_auto ) &
  fi

  fg=$(fg_pkg)
  if [ "$fg" != "$LAST_FG" ]; then
    log "前台切换: ${fg:-未知}"
    LAST_FG="$fg"
  fi
  if is_watched "$fg"; then
    start_server "前台 $fg"
    sleep 10
  else
    sleep "${POLL_DEAD:-6}"
  fi
done

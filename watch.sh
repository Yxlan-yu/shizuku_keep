#!/system/bin/sh
# =====================================================================
#  Shizuku 常驻守护 —— 应用列表管理工具
#
#  用法（需要 root）：
#    sh watch.sh list                      查看当前目标应用
#    sh watch.sh add   com.example.app     手动添加
#    sh watch.sh rm    com.example.app     移除
#    sh watch.sh auto                      立即重新扫描（自动发现）
#    sh watch.sh now                       立即拉起 Shizuku 服务
#
#  提示：ALWAYS_ON=1 时 Shizuku 是全局常驻的，任何应用都能用，
#        根本不需要往列表里加东西。只有切成 ALWAYS_ON=0 的按需模式
#        才需要这个列表。
# =====================================================================

case "$0" in
  */*) MODDIR=${0%/*} ;;
  *)   MODDIR=/data/adb/modules/shizuku_keep ;;
esac
CONF="$MODDIR/config.conf"
AUTOLIST=/data/adb/shizuku_keep.auto

[ "$(id -u)" = "0" ] || { echo "需要 root 权限运行"; exit 1; }

load() {
  ALWAYS_ON=1; WATCH_APPS=""; AUTO_WATCH=1
  # shellcheck disable=SC1090
  [ -f "$CONF" ] && . "$CONF"
}

set_watch() {
  NEW="$1"
  if grep -q '^WATCH_APPS=' "$CONF" 2>/dev/null; then
    sed -i "s|^WATCH_APPS=.*|WATCH_APPS=\"$NEW\"|" "$CONF"
  else
    echo "WATCH_APPS=\"$NEW\"" >>"$CONF"
  fi
}

cmd_list() {
  load
  echo "模式: $([ "$ALWAYS_ON" = "1" ] && echo '永久开启（全局，无需列表）' || echo '按需唤醒')"
  echo "自动发现: $([ "$AUTO_WATCH" = "1" ] && echo 开启 || echo 关闭)"
  echo ""
  echo "手工列表 WATCH_APPS:"
  if [ -z "$WATCH_APPS" ]; then echo "  (空)"; else
    for w in $WATCH_APPS; do echo "  - $w"; done
  fi
  echo ""
  echo "自动扫描结果 ($AUTOLIST):"
  if [ -f "$AUTOLIST" ] && [ -s "$AUTOLIST" ]; then
    sed 's/^/  - /' "$AUTOLIST"
  else
    echo "  (尚未扫描，执行 watch.sh auto)"
  fi
}

cmd_add() {
  p="$1"
  [ -z "$p" ] && { echo "用法: watch.sh add <包名>"; exit 1; }
  load
  case " $WATCH_APPS " in
    *" $p "*) echo "已在列表中: $p"; return 0 ;;
  esac
  set_watch "$(echo $WATCH_APPS $p)"
  echo "已添加: $p"
  cmd_show_app "$p"
}

cmd_rm() {
  p="$1"
  [ -z "$p" ] && { echo "用法: watch.sh rm <包名>"; exit 1; }
  load
  out=""
  for w in $WATCH_APPS; do
    [ "$w" = "$p" ] && continue
    out="$out $w"
  done
  set_watch "$(echo $out)"
  echo "已移除: $p"
}

cmd_show_app() {
  p="$1"
  n=$(dumpsys package "$p" 2>/dev/null | grep -m1 'moe\.shizuku\.manager\.permission' | wc -l)
  if [ "$n" -gt 0 ]; then
    echo "  ✓ $p 确实声明了 Shizuku 权限"
  else
    echo "  ! $p 没有声明 Shizuku 权限，可能填错包名，或它压根不用 Shizuku"
  fi
}

cmd_auto() {
  load
  echo "扫描中（约 10~20 秒）..."
  sh "$MODDIR/service.sh" --scan-only
  if [ -f "$AUTOLIST" ]; then
    echo "发现 $(wc -l <"$AUTOLIST") 个应用在用 Shizuku："
    sed 's/^/  - /' "$AUTOLIST"
  else
    echo "扫描失败"
  fi
}

cmd_now() {
  load
  echo "拉起 Shizuku..."
  if ! start_shizuku "命令行"; then
    echo "找不到 Shizuku 启动器（未安装，或 APK 内没有 native 库）"
    exit 1
  fi
  sleep 8
  p=$(shizuku_pids | awk '{print $1}')
  [ -n "$p" ] && echo "已启动 pid=$p" || echo "启动失败，看 /data/local/tmp/shizuku_starter.log"
}

# 公共函数（定位启动器 / 存活判断），配置先读一遍让 SHIZUKU_PKG 生效
# shellcheck disable=SC1091
[ -f "$CONF" ] && . "$CONF"
# shellcheck disable=SC1091
. "$MODDIR/common.sh"

case "$1" in
  list|ls)  cmd_list ;;
  add)      cmd_add "$2" ;;
  rm|del)   cmd_rm "$2" ;;
  auto)     cmd_auto ;;
  now)      cmd_now ;;
  *)        sed -n '4,20p' "$0" | sed 's/^#  \{0,1\}//' ;;
esac
#!/system/bin/sh
# =====================================================================
#  Shizuku 常驻守护 —— WebUI 后端
#  由 webroot/index.html 通过 KSU 的 ksu.exec 调用，全部以 root 执行
#  输出格式：管道分隔的单行结果，便于 JS 解析
# =====================================================================

case "$0" in
  */*) MODDIR=${0%/*} ;;
  *)   MODDIR=/data/adb/modules/shizuku_keep ;;
esac

CONF="$MODDIR/config.conf"
AUTOLIST=/data/adb/shizuku_keep.auto
NAMEFILE=/data/adb/shizuku_keep.names
LOGF="$MODDIR/keep.log"
STARTERLOG=/data/local/tmp/shizuku_starter.log
NRTMP=/data/local/tmp/shizuku_nr
CHUNK=225000

ALWAYS_ON=1
WATCH_APPS=""
AUTO_WATCH=1
EXCLUDE_APPS=""
POLL_DEAD=6
POLL_ALIVE=12
AUTO_RESCAN=1800
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

# 公共函数（定位启动器 / 存活判断 / 前台探测）
# shellcheck disable=SC1091
. "$MODDIR/common.sh"

# ---------- 配置写入 ----------
set_num() {
  if grep -q "^$1=" "$CONF" 2>/dev/null; then
    sed -i "s|^$1=.*|$1=$2|" "$CONF"
  else
    echo "$1=$2" >>"$CONF"
  fi
}

set_str() {
  if grep -q "^$1=" "$CONF" 2>/dev/null; then
    sed -i "s|^$1=.*|$1=\"$2\"|" "$CONF"
  else
    echo "$1=\"$2\"" >>"$CONF"
  fi
}

trim_ws() { echo $1; }

# ---------- status ----------
cmd_status() {
  p=$(shizuku_pids | awk '{print $1}')
  g=$(cat /data/adb/shizuku_keep.lock/pid 2>/dev/null)
  echo "mode=$ALWAYS_ON"
  echo "autowatch=$AUTO_WATCH"
  echo "poll_dead=$POLL_DEAD"
  echo "poll_alive=$POLL_ALIVE"
  if [ -n "$p" ]; then
    echo "svc=1"
    echo "svc_pid=$p"
    echo "svc_uid=$(stat -c %u /proc/$p 2>/dev/null)"
    echo "svc_ppid=$(awk '/^PPid/{print $2}' /proc/$p/status 2>/dev/null)"
    echo "svc_start=$(awk '{print int($22/100)}' /proc/$p/stat 2>/dev/null)"
  else
    echo "svc=0"
  fi
  if [ -n "$g" ] && [ -d "/proc/$g" ]; then
    echo "guard=1"
    echo "guard_pid=$g"
  else
    echo "guard=0"
  fi
  echo "uptime=$(cut -d. -f1 /proc/uptime 2>/dev/null)"
  echo "manual=$(trim_ws "$WATCH_APPS")"
  echo "exclude=$(trim_ws "$EXCLUDE_APPS")"
  echo "auto_count=$(wc -l <"$AUTOLIST" 2>/dev/null | tr -d ' ')"
  echo "log_size=$(wc -c <"$LOGF" 2>/dev/null | tr -d ' ')"
  echo "ksu_ver=$(getprop ro.kernelsu.version 2>/dev/null)"
}

# ---------- apps：合并手工 + 自动 ----------
cmd_apps() {
  for w in $WATCH_APPS; do echo "$w|manual"; done
  if [ -f "$AUTOLIST" ]; then
    while read -r p; do
      [ -z "$p" ] && continue
      case " $WATCH_APPS " in *" $p "*) continue ;; esac
      case " $EXCLUDE_APPS " in *" $p "*) continue ;; esac
      echo "$p|auto"
    done <"$AUTOLIST"
  fi
  for w in $EXCLUDE_APPS; do echo "$w|excluded"; done
}

# ---------- recent：最近打开过的应用 ----------
# 不同 ROM 的 dumpsys 字段不一样，两种格式都收：
#   HyperOS/MIUI  A=12345:com.foo
#   AOSP          u0 com.foo/.Act
# 再用 pm list packages -3 交叉验证，只留下真实安装的用户应用
cmd_recent() {
  tmp=/data/local/tmp/.sk_recent.$$
  pm list packages -3 2>/dev/null | sed 's/^package://' | tr -d '\r' >"$tmp" 2>/dev/null
  dumpsys activity recents 2>/dev/null | {
    grep -oE 'A=[0-9]+:[A-Za-z][A-Za-z0-9._]*' | sed 's/^A=[0-9]*://'
    grep -oE '[A-Za-z][A-Za-z0-9._]*/[A-Za-z0-9._$]+' | cut -d/ -f1
  } | awk 'NR==FNR { ok[$0]=1; next } NF && ok[$0] && !seen[$0]++' "$tmp" - | head -15
  rm -f "$tmp"
}

# ---------- 校验某个包是否真的用 Shizuku ----------
check_pkg() {
  dumpsys package "$1" 2>/dev/null | grep -q 'moe\.shizuku\.manager\.permission'
}

# ---------- 添加 ----------
cmd_add() {
  p=$(echo "$1" | tr -d ' \r\n')
  [ -z "$p" ] && { echo "err|包名不能为空"; exit 0; }
  echo "$p" | grep -qE '^[A-Za-z][A-Za-z0-9._]*$' || { echo "err|包名格式不正确"; exit 0; }

  if ! pm path "$p" >/dev/null 2>&1; then
    echo "err|未安装该应用：$p"
    exit 0
  fi

  case " $WATCH_APPS " in
    *" $p "*) echo "ok|已在列表中"; exit 0 ;;
  esac

  uses=0
  check_pkg "$p" && uses=1

  set_str WATCH_APPS "$(trim_ws "$WATCH_APPS $p")"

  # 从排除名单里拿掉
  new=""
  for w in $EXCLUDE_APPS; do [ "$w" = "$p" ] && continue; new="$new $w"; done
  [ "$(trim_ws "$new")" != "$(trim_ws "$EXCLUDE_APPS")" ] && set_str EXCLUDE_APPS "$(trim_ws "$new")"

  if [ "$uses" = "1" ]; then
    echo "ok|已添加 $p"
  else
    echo "ok|已添加 $p（注意：它没有申请 Shizuku 权限）"
  fi
}

# ---------- 移除 ----------
cmd_rm() {
  p=$(echo "$1" | tr -d ' \r\n')
  [ -z "$p" ] && { echo "err|包名不能为空"; exit 0; }

  new=""
  for w in $WATCH_APPS; do [ "$w" = "$p" ] && continue; new="$new $w"; done
  set_str WATCH_APPS "$(trim_ws "$new")"

  # 如果在自动发现结果里，加入排除名单，否则下次扫描又回来
  if [ -f "$AUTOLIST" ] && grep -qx "$p" "$AUTOLIST" 2>/dev/null; then
    case " $EXCLUDE_APPS " in
      *" $p "*) ;;
      *) set_str EXCLUDE_APPS "$(trim_ws "$EXCLUDE_APPS $p")" ;;
    esac
    echo "ok|已排除 $p"
  else
    echo "ok|已移除 $p"
  fi
}

# ---------- 恢复被排除的 ----------
cmd_restore() {
  p=$(echo "$1" | tr -d ' \r\n')
  new=""
  for w in $EXCLUDE_APPS; do [ "$w" = "$p" ] && continue; new="$new $w"; done
  set_str EXCLUDE_APPS "$(trim_ws "$new")"
  echo "ok|已恢复 $p"
}

# ---------- 模式 / 开关 ----------
cmd_mode() {
  case "$1" in
    0|1) set_num ALWAYS_ON "$1"; echo "ok|已切换为 $([ "$1" = "1" ] && echo 永久开启 || echo 按需唤醒)" ;;
    *)   echo "err|参数错误" ;;
  esac
}

cmd_autowatch() {
  case "$1" in
    0|1) set_num AUTO_WATCH "$1"; echo "ok|自动发现已$([ "$1" = "1" ] && echo 开启 || echo 关闭)" ;;
    *)   echo "err|参数错误" ;;
  esac
}

# ---------- 重启服务 ----------
cmd_restart() {
  for x in $(shizuku_pids); do kill -9 "$x" 2>/dev/null; done
  sleep 1
  if ! start_shizuku "WebUI 手动重启"; then
    echo "err|未安装 Shizuku，或 APK 内没有 native 库"
    exit 0
  fi
  sleep 7
  n=$(shizuku_pids | awk '{print $1}')
  [ -n "$n" ] && echo "ok|服务已重启 pid=$n" || echo "err|启动失败，请查看日志"
}

# ---------- 停止服务 ----------
cmd_stop() {
  for x in $(shizuku_pids); do kill -9 "$x" 2>/dev/null; done
  echo "ok|已停止（守护会在 6~12 秒内自动拉起）"
}

# ---------- 立即扫描 ----------
cmd_scan() {
  ( cd "$MODDIR" && nohup sh service.sh --scan-only >/dev/null 2>&1 </dev/null ) &
  echo "ok|扫描已开始，约 1 分钟"
}

# ---------- 日志（默认最新在上） ----------
cmd_log() {
  n=${1:-20}
  tail -"$n" "$LOGF" 2>/dev/null | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}'
}

# ---------- 应用名 / 图标：设备端只做搬运，解析交给前端 ----------
# 输出 apk 路径与压缩后的体积，前端据此决定分几块取
cmd_resprep() {
  p=$(echo "$1" | tr -d ' \r\n')
  APK=$(pm path "$p" 2>/dev/null | head -1 | cut -d: -f2)
  [ -z "$APK" ] && { echo "err|未安装该应用"; exit 0; }
  mkdir -p "$NRTMP" 2>/dev/null
  rm -f "$NRTMP"/*.gz 2>/dev/null
  f="$NRTMP/$(echo "$p" | tr '.' '_')"
  unzip -p "$APK" AndroidManifest.xml 2>/dev/null | gzip -1 >"$f.m.gz" 2>/dev/null
  unzip -p "$APK" resources.arsc 2>/dev/null | gzip -1 >"$f.a.gz" 2>/dev/null
  echo "apk=$APK"
  echo "m=$(wc -c <"$f.m.gz" 2>/dev/null | tr -d ' ')"
  echo "a=$(wc -c <"$f.a.gz" 2>/dev/null | tr -d ' ')"
}

# resdata <pkg> <m|a> <起始块> <块数>  → 每行 “块号|base64”
cmd_resdata() {
  p=$(echo "$1" | tr -d ' \r\n')
  w="$2"
  from=${3:-0}
  cnt=${4:-1}
  case "$w" in m|a) ;; *) echo "err|参数错误"; exit 0 ;; esac
  f="$NRTMP/$(echo "$p" | tr '.' '_').$w.gz"
  [ -f "$f" ] || { echo "err|还没有准备数据"; exit 0; }
  i=$from
  end=$((from + cnt))
  while [ "$i" -lt "$end" ]; do
    d=$(dd if="$f" bs=$CHUNK skip=$i count=1 2>/dev/null | base64 -w0)
    [ -z "$d" ] && break
    echo "$i|$d"
    i=$((i + 1))
  done
}

# 取图标（APK 内的单个资源文件），结果缓存到磁盘
# 注：新版 KernelSU 管理器自带 ksu://icon/<pkg>，前端优先走那条路，这里只是旧版兜底
cmd_iconfile() {
  p=$(echo "$1" | tr -d ' \r\n')
  rp=$(echo "$2" | tr -d '\r\n')
  echo "$rp" | grep -q '\.\.' && { echo "err|非法路径"; exit 0; }
  CDIR=/data/adb/shizuku_keep.icons
  CF="$CDIR/$p.$(echo "$rp" | tr '/' '_').b64"
  if [ -s "$CF" ]; then cat "$CF"; exit 0; fi
  APK=$(pm path "$p" 2>/dev/null | head -1 | cut -d: -f2)
  [ -z "$APK" ] && { echo "err|未安装该应用"; exit 0; }
  sz=$(unzip -l "$APK" "$rp" 2>/dev/null | awk 'NR==4{print $1}')
  [ -z "$sz" ] && { echo "err|图标不存在"; exit 0; }
  [ "$sz" -gt 300000 ] 2>/dev/null && { echo "err|图标过大"; exit 0; }
  b=$(unzip -p "$APK" "$rp" 2>/dev/null | base64 -w0)
  [ -z "$b" ] && { echo "err|读取失败"; exit 0; }
  mkdir -p "$CDIR" 2>/dev/null
  echo "$b" >"$CF" 2>/dev/null
  chmod 0644 "$CF" 2>/dev/null
  echo "$b"
}

# ---------- 应用名缓存（pkg <TAB> 名称 <TAB> 图标路径） ----------
cmd_names() {
  [ -f "$NAMEFILE" ] && cat "$NAMEFILE" 2>/dev/null
}

cmd_setname() {
  p=$(echo "$1" | tr -d ' \r\n')
  [ -z "$p" ] && { echo "err|缺少包名"; exit 0; }
  lb=$(echo "$2" | tr -d '\r\n\t')
  ic=$(echo "$3" | tr -d '\r\n\t')
  [ -z "$lb" ] && { echo "err|缺少名称"; exit 0; }
  [ "$ic" = "-" ] && ic=""
  touch "$NAMEFILE" 2>/dev/null
  awk -F'\t' -v k="$p" -v v="$lb" -v c="$ic" '
    BEGIN{done=0}
    $1==k { if(!done){ print k "\t" v "\t" c; done=1 }; next }
    { print }
    END { if(!done) print k "\t" v "\t" c }
  ' "$NAMEFILE" >"$NAMEFILE.tmp" 2>/dev/null && mv "$NAMEFILE.tmp" "$NAMEFILE"
  chmod 0644 "$NAMEFILE" 2>/dev/null
  echo "ok|已记录"
}

# ---------- 应用列表 ----------
# 默认只列「用户安装的应用」，把系统应用整体屏蔽掉（pm -3）
# 传 sys 参数时才返回全部（含系统应用），供前端「显示系统应用」用
cmd_allapps() {
  if [ "$1" = "sys" ] || [ "$1" = "all" ]; then
    pm list packages -e 2>/dev/null
  else
    pm list packages -3 -e 2>/dev/null
  fi | sed 's/^package://' | tr -d '\r' | sort -u
}

# ---------- 状态栏高度（物理像素）：给 WebUI 算顶部安全距离 ----------
cmd_insetbar() {
  h=$(dumpsys window 2>/dev/null | grep -m1 'type=statusBars' \
      | sed -n 's/.*frame=\[0,0\]\[[0-9]*,\([0-9]*\)\].*/\1/p')
  [ -z "$h" ] && h=$(dumpsys window 2>/dev/null | grep -m1 -o 'type=statusBars[^}]*' \
      | sed -n 's/.*top=\([0-9]*\).*/\1/p')
  # 再兜底：按 24dp 估算（各 ROM 状态栏的常见高度），总比 0 好
  if [ -z "$h" ] || [ "$h" = "0" ]; then
    dpi=$(wm density 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
    [ -n "$dpi" ] && h=$((dpi * 24 / 160))
  fi
  echo "${h:-0}"
}

# ---------- 守护重启 ----------
cmd_guard() {
  g=$(cat /data/adb/shizuku_keep.lock/pid 2>/dev/null)
  [ -n "$g" ] && kill -9 "$g" 2>/dev/null
  rm -rf /data/adb/shizuku_keep.lock
  sleep 1
  ( cd "$MODDIR" && nohup sh service.sh >/dev/null 2>&1 </dev/null ) &
  sleep 3
  echo "ok|守护已重启"
}

case "$1" in
  status)    cmd_status ;;
  apps)      cmd_apps ;;
  recent)    cmd_recent ;;
  add)       cmd_add "$2" ;;
  rm)        cmd_rm "$2" ;;
  restore)   cmd_restore "$2" ;;
  mode)      cmd_mode "$2" ;;
  autowatch) cmd_autowatch "$2" ;;
  restart)   cmd_restart ;;
  stop)      cmd_stop ;;
  scan)      cmd_scan ;;
  log)       cmd_log "$2" ;;
  guard)     cmd_guard ;;
  resprep)   cmd_resprep "$2" ;;
  resdata)   cmd_resdata "$2" "$3" "$4" "$5" ;;
  iconfile)  cmd_iconfile "$2" "$3" ;;
  names)     cmd_names ;;
  setname)   shift; cmd_setname "$@" ;;
  allapps)   cmd_allapps "$2" ;;
  insetbar)  cmd_insetbar ;;
  *)         echo "err|未知命令: $1" ;;
esac

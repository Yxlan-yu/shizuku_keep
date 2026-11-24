#!/system/bin/sh
# =====================================================================
#  Shizuku 常驻守护 —— 公共函数
#  被 service.sh / webui.sh / watch.sh source
#
#  这里的实现刻意不绑定某个 ROM / 机型：
#    · Shizuku 的 native 启动器按 ABI 优先级 + pm path 的全部路径去找
#      （覆盖 ABI split：lib 可能不在 base.apk 里）
#    · 前台应用探测走多字段兜底，不依赖 topResumedActivity 是否存在
#    · 进程存活判断 pidof → pgrep → ps -o 三级兜底
# =====================================================================

: "${MODDIR:=/data/adb/modules/shizuku_keep}"
SHIZUKU_PKG="${SHIZUKU_PKG:-moe.shizuku.privileged.api}"
STARTERLOG="${STARTERLOG:-/data/local/tmp/shizuku_starter.log}"

# 列出 Shizuku 的全部 APK（base + split）
shizuku_apks() {
  pm path "$SHIZUKU_PKG" 2>/dev/null | sed 's/^package://' | tr -d '\r'
}

# ABI 字符串 → Shizuku APK 内的 lib 子目录名
abi_dir() {
  case "$1" in
    arm64*|aarch64*) echo arm64 ;;
    armeabi*|armv7*|arm) echo arm ;;
    x86_64*) echo x86_64 ;;
    x86) echo x86 ;;
    riscv64*) echo riscv64 ;;
    *) return 1 ;;
  esac
}

# 设备支持的 ABI，主 ABI 优先，去重
shizuku_abilist() {
  {
    getprop ro.product.cpu.abi 2>/dev/null
    getprop ro.product.cpu.abilist 2>/dev/null | tr ',' ' '
    getprop ro.product.cpu.abilist32 2>/dev/null | tr ',' ' '
    getprop ro.product.cpu.abi2 2>/dev/null
  } | tr -d '\r' | tr ' ' '\n' | awk 'NF && !seen[$0]++'
}

# 定位 Shizuku 的 native 启动器（libshizuku.so），找不到返回 1
find_starter() {
  for apk in $(shizuku_apks); do
    dir=${apk%/*}
    for abi in $(shizuku_abilist); do
      d=$(abi_dir "$abi") || continue
      for cand in "$dir/lib/$d/libshizuku.so" "$dir/lib/$d/libshizuku_starter.so"; do
        if [ -f "$cand" ] && [ -r "$cand" ]; then
          echo "$cand"
          return 0
        fi
      done
    done
    # 兜底：直接扫 lib 下所有 ABI 目录
    for cand in "$dir"/lib/*/libshizuku.so "$dir"/lib/*/libshizuku_starter.so; do
      if [ -f "$cand" ] && [ -r "$cand" ]; then
        echo "$cand"
        return 0
      fi
    done
  done
  return 1
}

# shizuku_server 的 pid 列表
# 注意：不能用 pgrep -f —— 它会匹配任意含 "shizuku_server" 字样的命令行
# （包括正在执行本函数的 shell），从而把"服务已死"误判成"还活着"
shizuku_pids() {
  p=$(pidof shizuku_server 2>/dev/null)
  [ -z "$p" ] && p=$(pgrep -x shizuku_server 2>/dev/null)
  [ -z "$p" ] && p=$(ps -A -o PID,NAME 2>/dev/null | awk '$2 == "shizuku_server" { print $1 }')
  echo "$p"
}

shizuku_alive() {
  [ -n "$(shizuku_pids)" ]
}

# 拉起 Shizuku，$1 = 缘由（仅用于日志）
start_shizuku() {
  starter=$(find_starter)
  if [ -z "$starter" ]; then
    echo "找不到 Shizuku 启动器（未安装 Shizuku，或 APK 内没有 native 库）"
    return 1
  fi
  # 启动器会在自己的进程里切 namespace / cgroup，必须脱离当前会话
  ( cd /data/local/tmp && "$starter" >"$STARTERLOG" 2>&1 </dev/null ) &
  return 0
}

# 当前前台应用包名；取不到时输出空
fg_pkg() {
  line=$(dumpsys activity activities 2>/dev/null \
    | grep -m1 -E '(topResumedActivity|mResumedActivity|ResumedActivity)[=:]')
  if [ -z "$line" ]; then
    line=$(dumpsys window 2>/dev/null | grep -m1 -E 'mCurrentFocus=|mFocusedApp=')
  fi
  if [ -z "$line" ]; then
    line=$(dumpsys activity top 2>/dev/null | grep -m1 'ACTIVITY ')
  fi
  [ -z "$line" ] && return 0
  echo "$line" | grep -oE '[A-Za-z][A-Za-z0-9._]*/[A-Za-z0-9._$]+' | head -1 | cut -d/ -f1
}

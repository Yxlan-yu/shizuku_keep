#!/system/bin/sh
# =====================================================================
#  uninstall.sh —— 模块被卸载时执行
#  只清运行期产生的缓存和锁，模块目录本身由管理器删除。
#  不动 shizuku_server：卸载的是守护模块，Shizuku 本体该继续能用。
# =====================================================================

LOCK=/data/adb/shizuku_keep.lock

# 先停守护，否则它可能边删边写日志 / 把服务重新拉起来
guard=$(cat "$LOCK/pid" 2>/dev/null)
[ -n "$guard" ] && kill -9 "$guard" 2>/dev/null
sleep 1
rm -rf "$LOCK"

# 自动发现结果、应用名/图标缓存、遗留 pid 文件
rm -f /data/adb/shizuku_keep.auto \
      /data/adb/shizuku_keep.auto.tmp \
      /data/adb/shizuku_keep.auto.new \
      /data/adb/shizuku_keep.names \
      /data/adb/shizuku_keep.names.tmp \
      /data/adb/shizuku_keep.pid
rm -rf /data/adb/shizuku_keep.icons

# 临时文件（放在 tmp 是因为启动器在模块目录里跑 pm 会失败）
rm -rf /data/local/tmp/shizuku_nr
rm -f /data/local/tmp/shizuku_starter.log

#!/system/bin/sh
# KSU 安装时执行
SKIPUNZIP=0

# 升级时保留已有配置（覆盖安装不会重置模式/应用列表）
OLD_CONF=/data/adb/modules/shizuku_keep/config.conf
if [ -f "$OLD_CONF" ] && [ "$OLD_CONF" != "$MODPATH/config.conf" ]; then
  cp -f "$OLD_CONF" "$MODPATH/config.conf" 2>/dev/null && ui_print "- 已保留原有 config.conf"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/boot-completed.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/watch.sh" 0 0 0755
set_perm "$MODPATH/webui.sh" 0 0 0755
set_perm "$MODPATH/common.sh" 0 0 0644
set_perm_recursive "$MODPATH/webroot" 0 0 0755 0644
set_perm "$MODPATH/config.conf" 0 0 0644
set_perm "$MODPATH/module.prop" 0 0 0644
ui_print "- Shizuku 常驻守护已安装"
ui_print "- 默认永久开启：开机自动拉起，任何用 Shizuku 的应用都能授权"
ui_print "- 打开 KernelSU 管理器里的「WebUI」按钮即可图形化管理"
ui_print "- 想改成按需唤醒：WebUI 里切换，或改 config.conf 的 ALWAYS_ON=0"
ui_print "- 命令行：su -c 'sh $MODPATH/watch.sh list'"
ui_print "- 重启后生效；不想重启就进 WebUI 点「重启服务」"

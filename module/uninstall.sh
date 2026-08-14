#!/system/bin/sh
# ============================================================
# sing-box for Android - 卸载脚本
# 停止服务并清理 iptables 规则; 用户数据 (/data/adb/sing-box_module) 默认保留
# ============================================================

MODDIR=${0%/*}
SCRIPTS_DIR="$MODDIR/scripts"

# 停止 inotifyd 监控
for pid in $(pidof inotifyd 2>/dev/null); do
  grep -Eq 'sing-box\.inotify|config\.inotify|net\.inotify' /proc/$pid/cmdline 2>/dev/null && kill "$pid" 2>/dev/null
done

# 停止服务 (会顺带清理 iptables 规则)
if [ -f "$SCRIPTS_DIR/sing-box.service" ]; then
  sh "$SCRIPTS_DIR/sing-box.service" stop >/dev/null 2>&1
fi

# Remove the module-owned local-address bypass chain even if the service was
# already stopped or its previous runtime configuration is no longer present.
if [ -f "$SCRIPTS_DIR/tproxy.sh" ]; then
  sh "$SCRIPTS_DIR/tproxy.sh" cleanup >/dev/null 2>&1
fi

# 兜底清理透明代理规则 (防残留)
TPROXY_SCRIPT=/data/adb/sing-box_module/bin/atp
if [ -f "$TPROXY_SCRIPT" ]; then
  TPROXY_DIR=/data/adb/sing-box_module/config/run/tproxy
  [ -f "$TPROXY_DIR/tproxy.conf" ] || TPROXY_DIR=/data/adb/sing-box_module/scripts
  sh "$TPROXY_SCRIPT" -d "$TPROXY_DIR" stop >/dev/null 2>&1
fi

echo "- sing-box 服务已停止"
echo "- 数据保留在 /data/adb/sing-box_module (如需彻底删除请手动删除)"

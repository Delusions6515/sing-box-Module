#!/system/bin/sh
# ============================================================
# sing-box for Android - 开机启动脚本 (late_start service 模式)
# 系统启动完成后启动 sing-box
# 并监控模块目录, 禁用/启用模块时自动停止/启动服务
# ============================================================

MODDIR=${0%/*}
SCRIPTS_DIR="$MODDIR/scripts"

start_watchers() {
  . "$SCRIPTS_DIR/lib.sh"
  load_config
  inotifyd "$SCRIPTS_DIR/sing-box.inotify" "$MODDIR" >/dev/null 2>&1 &
  inotifyd "$SCRIPTS_DIR/config.inotify" \
    "$user_scripts_path" "$local_config_path" "$remote_config_path" >/dev/null 2>&1 &
}

# 等待系统启动完成后再拉起服务
(
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 3
  done
  sh "$SCRIPTS_DIR/start.sh"
  start_watchers
) &

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
    "$user_scripts_path" "$local_config_path" "$remote_config_path" "$user_inbounds_path" "$config_root" >/dev/null 2>&1 &

  # sysfs 不支持 inotify (inotifyd 挂 /sys/class/net 能注册但永远收不到事件),
  # 改监控 /data/misc/net: netd 会写入该目录, 可可靠触发 w 事件。
  # 等待 rt_tables 就绪后再挂载; 上限 60 次 (3 分钟), 防止极端情况挂死子 shell。
  _rt_wait=0
  while [ ! -f /data/misc/net/rt_tables ] ; do
    sleep 3
    _rt_wait=$((_rt_wait + 1))
    if [ "$_rt_wait" -ge 60 ]; then
      echo "[Warn] /data/misc/net/rt_tables 未出现, 跳过网络变化监控"
      return 0
    fi
  done
  inotifyd "$SCRIPTS_DIR/net.inotify" /data/misc/net >/dev/null 2>&1 &
}

# 等待系统启动完成后再拉起服务
(
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 3
  done
  sh "$SCRIPTS_DIR/start.sh"
  start_watchers
) &

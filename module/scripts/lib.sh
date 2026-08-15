#!/system/bin/sh
# ============================================================
# sing-box for Android - 公共函数库
# 被模块内其它脚本 source, 不单独执行
# 注意: 运行环境为 busybox ash, 勿使用 bash 数组等特性
# ============================================================

# ---------- 操作日志轮转 ----------
# 归档 run.log / run_error.log 为 .bak，新文件只含后续操作输出。
rotate_run_log() {
  mv "$run_path/run.log" "$run_path/run.log.bak" >/dev/null 2>&1
  mv "$run_path/run_error.log" "$run_path/run_error.log.bak" >/dev/null 2>&1
}

# ---------- 配置加载 ----------
# 模块脚本始终位于安装目录；用户可编辑设置固定在数据目录 scripts/。
load_config() {
  USER_CONFIG_DIR=/data/adb/sing-box_module/scripts
  if [ -f "$USER_CONFIG_DIR/sing-box.config" ]; then
    CONFIG_DIR="$USER_CONFIG_DIR"
    CONFIG_FILE="$CONFIG_DIR/sing-box.config"
  else
    CONFIG_DIR="$SCRIPTS_DIR"
    CONFIG_FILE="$SCRIPTS_DIR/sing-box.config"
  fi
  # shellcheck disable=SC1090
  . "$CONFIG_FILE" 2>/dev/null || {
    echo "[Error] 配置文件加载失败: $CONFIG_FILE"
    exit 1
  }
  # 数据目录: 以配置为准, 无配置时回退默认
  sing_box_path="${sing_box_path:-/data/adb/sing-box_module}"
  user_scripts_path="${sing_box_path}/scripts"
  config_root="${sing_box_path}/config"
  local_config_path="${config_root}/local"
  remote_config_path="${config_root}/remote"
  user_inbounds_path="${config_root}/inbounds"
  inbound_template_path="${user_inbounds_path}/tpl"
  runtime_config_dir="${config_root}/run"
  run_path="${sing_box_path}/run"
  subscription_file="${user_scripts_path}/subscription.json"
  runtime_config_path="${runtime_config_dir}/config.json"
  runtime_tproxy_dir="${runtime_config_dir}/tproxy"
  proxy_package_list_file="${config_root}/proxy_package_name"
  force_proxy_apps_file="${user_scripts_path}/force_proxy_app.txt"
  force_bypass_apps_file="${user_scripts_path}/force_bypass_app.txt"
  auto_proxy_apps_file="${runtime_config_dir}/proxy_apps.list"
  auto_bypass_apps_file="${runtime_config_dir}/bypass_apps.list"
  app_proxy_enabled_file="${runtime_config_dir}/app_proxy.enabled"
  app_proxy_mode_file="${runtime_config_dir}/app_proxy.mode"
  service_pid_file="${run_path}/${bin_name:-sing-box}.pid"
  tproxy_state_file="${run_path}/tproxy.active"
}

resolve_active_config() {
  _jq="${jq_path:-$sing_box_path/bin/jq}"
  [ -x "$_jq" ] || { err "缺少 jq: $_jq"; return 1; }
  [ -f "$subscription_file" ] || { err "缺少订阅索引: $subscription_file"; return 1; }
  _active_type=$("$_jq" -r '
    .active as $active
    | .subscriptions[]?
    | select(.name == $active)
    | .type // empty
  ' "$subscription_file" 2>/dev/null)
  _active_filename=$("$_jq" -r '
    .active as $active
    | .subscriptions[]?
    | select(.name == $active)
    | .filename // empty
  ' "$subscription_file" 2>/dev/null)
  case "$_active_type" in
    local) _active_dir=$local_config_path ;;
    remote) _active_dir=$remote_config_path ;;
    *) err "订阅索引中的当前配置类型无效"; return 1 ;;
  esac
  case "$_active_filename" in
    ''|.*|*/*|*'..'*|*[!A-Za-z0-9._-]*) err "订阅索引中的当前配置文件名无效"; return 1 ;;
  esac
  active_config_path="${_active_dir}/$_active_filename"
  [ -f "$active_config_path" ] || { err "当前配置不存在: $active_config_path"; return 1; }
}

# ---------- 状态检测 ----------
service_process_matches() { # $1=pid
  [ -r "/proc/$1/cmdline" ] || return 1
  _service_cmdline=$(tr '\000' ' ' <"/proc/$1/cmdline" 2>/dev/null)
  case "$_service_cmdline" in
    *"$bin_path"*"run -c $runtime_config_path"*) return 0 ;;
  esac
  return 1
}

find_service_pid() {
  for _service_proc in /proc/[0-9]*; do
    _service_pid=${_service_proc#/proc/}
    service_process_matches "$_service_pid" && {
      printf '%s\n' "$_service_pid"
      return 0
    }
  done
  return 1
}

service_running() {
  _service_pid=""
  if [ -f "$service_pid_file" ]; then
    _service_pid=$(cat "$service_pid_file" 2>/dev/null)
  fi
  case "$_service_pid" in
    *[!0-9]*|'') _service_pid="" ;;
  esac
  if [ -n "$_service_pid" ] \
    && kill -0 "$_service_pid" 2>/dev/null \
    && service_process_matches "$_service_pid"; then
    return 0
  fi

  _service_pid=$(find_service_pid)
  if [ -n "$_service_pid" ]; then
    printf '%s\n' "$_service_pid" >"$service_pid_file" 2>/dev/null
    return 0
  fi
  rm -f "$service_pid_file"
  return 1
}

autostart_enabled() {
  [ ! -f "$sing_box_path/manual" ]
}

# ---------- JSON 输出 (WebUI 用) ----------
json_escape() {
  printf '%s' "$1" | awk 'BEGIN { ORS="" }
    {
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      gsub(/\r/, "\\r")
      gsub(/\n/, "\\n")
      print
    }'
}

print_status_json() {
  load_config

  if service_running; then
    _service_running=true
  else
    _service_running=false
  fi

  if autostart_enabled; then
    _autostart=true
  else
    _autostart=false
  fi

  # 当前内核版本
  _kernel_version=$(cat "$sing_box_path/bin/kernel_version" 2>/dev/null || echo unknown)

  printf '{'
  printf '"serviceRunning":%s,' "$_service_running"
  printf '"autostart":%s,' "$_autostart"
  resolve_active_config >/dev/null 2>&1 || active_config_path=""
  printf '"kernelVersion":"%s",' "$(json_escape "$_kernel_version")"
  printf '"activeConfig":"%s"' "$(json_escape "${active_config_path#$config_root/}")"
  printf '}\n'
}

# ---------- 动作 ----------
toggle_autostart() {
  if autostart_enabled; then
    touch "$sing_box_path/manual"
    echo "已禁用开机自启 (下次重启不再自动启动, 可手动执行启动)"
  else
    rm -f "$sing_box_path/manual"
    echo "已启用开机自启 (下次重启自动启动)"
  fi
}

# ---------- 下载: curl 优先, 回退 wget ----------
download() {  # $1=url  $2=输出文件路径
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 600 --retry 3 --retry-delay 2 --retry-max-time 60 "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    err "未找到 curl / wget, 无法下载"
    return 127
  fi
}

# ---------- 抓取文本 (版本号 / API) ----------
fetch_text() {  # $1=url
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 30 "$1" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1" 2>/dev/null
  fi
}

# ---------- 输出 ----------
info() { echo "[Info] $1"; }
warn() { echo "[Warn] $1"; }
err()  { echo "[Error] $1"; }

# ---------- 服务控制 ----------
restart_service() {
  sh "$SCRIPTS_DIR/sing-box.service" restart >>"$run_path/run.log" 2>>"$run_path/run_error.log"
}
stop_service() {
  sh "$SCRIPTS_DIR/sing-box.service" stop >>"$run_path/run.log" 2>>"$run_path/run_error.log"
}

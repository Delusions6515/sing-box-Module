#!/system/bin/sh
# Build the disposable sing-box configuration from the selected complete config.

SCRIPTS_DIR=$(dirname "$0")
. "$SCRIPTS_DIR/lib.sh"
load_config
APP_LIST_TOOL="$SCRIPTS_DIR/app-list.sh"

resolve_mode_inbound() {
  case "$proxy_mode" in
    ''|*[!A-Za-z0-9_-]*) echo "[Error] proxy_mode 只能包含字母、数字、_ 或 -" >&2; return 1 ;;
  esac
  _inbound_name="${proxy_mode}.json"
  if [ -f "$user_inbounds_path/$_inbound_name" ]; then
    selected_inbound_path="$user_inbounds_path/$_inbound_name"
  elif [ -f "$inbound_template_path/$_inbound_name" ]; then
    selected_inbound_path="$inbound_template_path/$_inbound_name"
  else
    selected_inbound_path=""
  fi
}

load_mode_inbound() {
  _jq=$1
  case "$proxy_mode" in
    redirect|tproxy)
      _tproxy_config="$user_scripts_path/tproxy.conf"
      [ -f "$_tproxy_config" ] || { echo "[Error] 缺少透明代理配置: $_tproxy_config" >&2; return 1; }
      # Keep the AndroidTProxyShell port and inbound port on one contract.
      # shellcheck disable=SC1090
      . "$_tproxy_config"
      _port=${PROXY_TCP_PORT:-1536}
      case "$_port" in
        *[!0-9]*|'') echo "[Error] PROXY_TCP_PORT 必须是数字" >&2; return 1 ;;
      esac
      if [ "$proxy_mode" = "tproxy" ] && [ "${PROXY_UDP_PORT:-$_port}" != "$_port" ]; then
        echo "[Error] tproxy 模式要求 PROXY_TCP_PORT 与 PROXY_UDP_PORT 相同" >&2
        return 1
      fi
      "$_jq" -c --argjson port "$_port" '
        if type != "object" then error("inbound must be an object")
        else .listen_port = $port end
      ' "$selected_inbound_path"
      ;;
    *)
      _app_proxy_enabled=0
      _app_proxy_mode=""
      [ -f "$app_proxy_enabled_file" ] && _app_proxy_enabled=$(cat "$app_proxy_enabled_file")
      [ -f "$app_proxy_mode_file" ] && _app_proxy_mode=$(cat "$app_proxy_mode_file")
      case "$_app_proxy_enabled:$_app_proxy_mode" in
        1:whitelist)
          _package_field=include_package
          _other_package_field=exclude_package
          _package_list_file=$auto_proxy_apps_file
          ;;
        1:blacklist)
          _package_field=exclude_package
          _other_package_field=include_package
          _package_list_file=$auto_bypass_apps_file
          ;;
        0:*)
          "$_jq" -c '
            if type != "object" then error("inbound must be an object")
            elif .type == "tun" or .type == "ebpf" then
              del(.include_package, .exclude_package)
            else . end
          ' "$selected_inbound_path"
          return
          ;;
        *)
          echo "[Error] 分应用代理运行状态无效" >&2
          return 1
          ;;
      esac
      "$_jq" -c \
        --arg package_field "$_package_field" \
        --arg other_package_field "$_other_package_field" \
        --rawfile packages "$_package_list_file" '
        if type != "object" then error("inbound must be an object")
        elif .type == "tun" or .type == "ebpf" then
          .[$package_field] = ($packages | split("\n") | map(select(length > 0)))
          | del(.[$other_package_field])
        else . end
      ' "$selected_inbound_path"
      ;;
  esac
}

build_runtime_config() {
  _jq="${jq_path:-$sing_box_path/bin/jq}"
  [ -x "$_jq" ] || { echo "[Error] 缺少 jq: $_jq" >&2; return 1; }
  resolve_active_config || return 1
  mkdir -p "$runtime_config_dir" || return 1

  if [ "$proxy_mode" != "none" ] && ! sh "$APP_LIST_TOOL" build; then
    return 1
  fi

  resolve_mode_inbound || return 1
  if [ -n "$selected_inbound_path" ]; then
    _inbound=$(load_mode_inbound "$_jq") || return 1
    _filter='if (.inbounds // [] | type) != "array" then error("inbounds must be an array") else . end | .inbounds = ((.inbounds // []) + [$inbound])'
    "$_jq" --argjson inbound "$_inbound" "$_filter" "$active_config_path" >"$runtime_config_path.new" || {
      rm -f "$runtime_config_path.new"
      return 1
    }
  else
    "$_jq" . "$active_config_path" >"$runtime_config_path.new" || {
      rm -f "$runtime_config_path.new"
      return 1
    }
  fi
  mv -f "$runtime_config_path.new" "$runtime_config_path"
}

case "$1" in
  build) build_runtime_config ;;
  *) echo "用法: $0 build" >&2; exit 2 ;;
esac

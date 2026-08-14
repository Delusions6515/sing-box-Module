#!/system/bin/sh
# Generate final per-app proxy and bypass lists for the active Android user.

SCRIPTS_DIR=$(dirname "$0")
. "$SCRIPTS_DIR/lib.sh"
load_config

PROXY_PACKAGE_LIST_URL="https://raw.githubusercontent.com/2dust/v2rayNG/master/V2rayNG/app/src/main/assets/proxy_package_name"

normalize_packages() {
  case "$1" in
    -) cat ;;
    *) cat "$1" ;;
  esac | awk '
    {
      sub(/\r$/, "")
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      if ($0 ~ /^#/) next
      gsub(/[[:space:]]+/, "\n")
      print
    }
  ' | awk '
    {
      sub(/^package:/, "")
      sub(/^[0-9]+:/, "")
    }
    $0 !~ /^#/ && $0 ~ /^[A-Za-z][A-Za-z0-9_.]*$/ && !seen[$0]++ { print }
  '
}

remove_forced_packages() { # $1=force list, $2=candidate list
  [ -s "$1" ] || { cat "$2"; return; }
  awk 'FNR == NR { forced[$0] = 1; next } !forced[$0]' "$1" "$2"
}

current_user() {
  _user=$(cmd activity get-current-user 2>/dev/null)
  case "$_user" in *[!0-9]*|'') _user=$(am get-current-user 2>/dev/null) ;; esac
  case "$_user" in *[!0-9]*|'') _user=0 ;; esac
  printf '%s\n' "$_user"
}

installed_packages() {
  _user=${1:-$(current_user)}
  pm list packages --user "$_user" 2>/dev/null || pm list packages 2>/dev/null
}

load_app_proxy_settings() {
  case "${app_proxy_enable:-0}" in 0|1) ;; *) err "app_proxy_enable 必须为 0 或 1"; return 1 ;; esac
  case "${app_proxy_mode:-whitelist}" in blacklist|whitelist) ;; *) err "app_proxy_mode 必须为 blacklist 或 whitelist"; return 1 ;; esac
  case "${auto_proxy_apps_enable:-0}" in 0|1) ;; *) err "auto_proxy_apps_enable 必须为 0 或 1"; return 1 ;; esac
}

build_lists() {
  load_app_proxy_settings || return 1
  mkdir -p "$runtime_config_dir" || return 1
  if [ "${app_proxy_enable:-0}" = "0" ] \
    && [ -z "$(normalize_packages "$force_proxy_apps_file" 2>/dev/null)" ] \
    && [ -z "$(normalize_packages "$force_bypass_apps_file" 2>/dev/null)" ]; then
    : >"$auto_proxy_apps_file"
    : >"$auto_bypass_apps_file"
    echo 0 >"$app_proxy_enabled_file"
    echo "${app_proxy_mode:-whitelist}" >"$app_proxy_mode_file"
    return 0
  fi
  _tmp_dir="$runtime_config_dir/.app-lists.$$"
  mkdir "$_tmp_dir" || return 1

  installed_packages | normalize_packages - >"$_tmp_dir/installed"
  if [ ! -s "$_tmp_dir/installed" ]; then
    rm -rf "$_tmp_dir"
    err "无法获取当前用户的已安装应用"
    return 1
  fi
  printf '%s\n' "${proxy_apps_list:-}" | normalize_packages - >"$_tmp_dir/manual-proxy"
  printf '%s\n' "${bypass_apps_list:-}" | normalize_packages - >"$_tmp_dir/manual-bypass"
  [ -f "$force_proxy_apps_file" ] && normalize_packages "$force_proxy_apps_file" >"$_tmp_dir/force-proxy" || : >"$_tmp_dir/force-proxy"
  [ -f "$force_bypass_apps_file" ] && normalize_packages "$force_bypass_apps_file" >"$_tmp_dir/force-bypass" || : >"$_tmp_dir/force-bypass"

  if [ "${auto_proxy_apps_enable:-0}" = "1" ]; then
    [ -f "$proxy_package_list_file" ] || {
      rm -rf "$_tmp_dir"
      err "缺少代理应用名单: $proxy_package_list_file"
      return 1
    }
    normalize_packages "$proxy_package_list_file" >"$_tmp_dir/catalog"
    awk 'FNR == NR { wanted[$0] = 1; next } wanted[$0]' \
      "$_tmp_dir/catalog" "$_tmp_dir/installed" >"$_tmp_dir/auto-proxy"
    awk 'FNR == NR { wanted[$0] = 1; next } !wanted[$0]' \
      "$_tmp_dir/catalog" "$_tmp_dir/installed" >"$_tmp_dir/auto-bypass"
  else
    : >"$_tmp_dir/auto-proxy"
    : >"$_tmp_dir/auto-bypass"
  fi

  _effective_mode=${app_proxy_mode:-whitelist}
  # With filtering disabled, preserve the ordinary "proxy all" behavior and
  # apply a force-bypass entry as an exception.
  [ "${app_proxy_enable:-0}" = "0" ] && _effective_mode=blacklist
  if [ "$_effective_mode" = "blacklist" ]; then
    cat "$_tmp_dir/auto-bypass" "$_tmp_dir/manual-bypass" "$_tmp_dir/force-bypass" \
      | normalize_packages - >"$_tmp_dir/bypass-candidates"
    remove_forced_packages "$_tmp_dir/force-proxy" "$_tmp_dir/bypass-candidates" >"$_tmp_dir/bypass-wanted"
    awk 'FNR == NR { wanted[$0] = 1; next } wanted[$0]' \
      "$_tmp_dir/bypass-wanted" "$_tmp_dir/installed" >"$_tmp_dir/bypass"
    awk 'FNR == NR { bypass[$0] = 1; next } !bypass[$0]' \
      "$_tmp_dir/bypass" "$_tmp_dir/installed" >"$_tmp_dir/proxy"
    echo 1 >"$_tmp_dir/enabled"
  else
    cat "$_tmp_dir/auto-proxy" "$_tmp_dir/manual-proxy" "$_tmp_dir/force-proxy" \
      | normalize_packages - >"$_tmp_dir/proxy-candidates"
    remove_forced_packages "$_tmp_dir/force-bypass" "$_tmp_dir/proxy-candidates" >"$_tmp_dir/proxy-wanted"
    awk 'FNR == NR { wanted[$0] = 1; next } wanted[$0]' \
      "$_tmp_dir/proxy-wanted" "$_tmp_dir/installed" >"$_tmp_dir/proxy"
    awk 'FNR == NR { proxy[$0] = 1; next } !proxy[$0]' \
      "$_tmp_dir/proxy" "$_tmp_dir/installed" >"$_tmp_dir/bypass"
    echo 1 >"$_tmp_dir/enabled"
  fi

  mv -f "$_tmp_dir/proxy" "$auto_proxy_apps_file"
  mv -f "$_tmp_dir/bypass" "$auto_bypass_apps_file"
  mv -f "$_tmp_dir/enabled" "$app_proxy_enabled_file"
  echo "$_effective_mode" >"$app_proxy_mode_file"
  rm -rf "$_tmp_dir"
}

update_proxy_package_list() {
  mkdir -p "$config_root" || return 1
  download "$PROXY_PACKAGE_LIST_URL" "$proxy_package_list_file.new" || return 1
  if ! normalize_packages "$proxy_package_list_file.new" | awk 'NR == 1 { found = 1 } END { exit !found }'; then
    rm -f "$proxy_package_list_file.new"
    err "下载的代理应用名单为空或格式无效"
    return 1
  fi
  mv -f "$proxy_package_list_file.new" "$proxy_package_list_file"
  info "代理应用名单已更新"
}

case "$1" in
  build) build_lists ;;
  update-proxy-package-list) update_proxy_package_list ;;
  *) echo "用法: $0 {build|update-proxy-package-list}" >&2; exit 2 ;;
esac

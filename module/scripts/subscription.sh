#!/system/bin/sh
# Subscription index and complete-config selection helper.

SCRIPTS_DIR=$(dirname "$0")
. "$SCRIPTS_DIR/lib.sh"
load_config

jq_bin="${jq_path:-$sing_box_path/bin/jq}"

require_jq() {
  [ -x "$jq_bin" ] || { err "缺少 jq: $jq_bin"; return 1; }
}

ensure_subscription_store() {
  require_jq || return 1
  mkdir -p "$user_scripts_path" "$local_config_path" "$remote_config_path" "$user_inbounds_path" "$inbound_template_path" "$runtime_config_dir" "$run_path" || return 1
  if [ ! -f "$local_config_path/default.json" ]; then
    cp -f "$SCRIPTS_DIR/config.json.tpl" "$local_config_path/default.json" || return 1
  fi
  if [ ! -f "$subscription_file" ]; then
    printf '%s\n' '{' \
      '  "active": "default",' \
      '  "subscriptions": [' \
      '    {"name":"default","type":"local","path":"local/default.json","url":null,"updated_at":null}' \
      '  ]' \
      '}' >"$subscription_file"
  fi
  "$jq_bin" -e '
    (.active | type == "string") and
    (.subscriptions | type == "array" and length > 0) and
    ([.subscriptions[] | .name] as $names
      | ($names | all(type == "string"))
      and ($names | length) == (.subscriptions | length)
      and ($names | length) == ($names | unique | length))
    and (.active as $active | [.subscriptions[] | .name] | index($active) != null)
    and all(.subscriptions[];
      (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
      (.type == "local" or .type == "remote") and
      (.path | type == "string") and
      (.path | startswith("/") | not) and
      (.path | contains("..") | not) and
      (if .type == "local" then
         (.path | startswith("local/")) and (.url == null)
       else
         (.path | startswith("remote/")) and (.url | type == "string" and length > 0)
       end) and
      ((.updated_at // null) | type == "null" or type == "string")
    )
  ' "$subscription_file" >/dev/null || {
    err "订阅索引格式无效: $subscription_file"
    return 1
  }
}

active_subscription() {
  ensure_subscription_store || return 1
  "$jq_bin" -r '.active' "$subscription_file"
}

list_subscriptions() {
  ensure_subscription_store || return 1
  "$jq_bin" -r '.subscriptions[] | [.name, .type, (.url // .path)] | @tsv' "$subscription_file"
}

select_subscription() {
  _name=$1
  ensure_subscription_store || return 1
  "$jq_bin" -e --arg name "$_name" 'any(.subscriptions[]; .name == $name)' "$subscription_file" >/dev/null || {
    err "未找到配置: $_name"
    return 1
  }
  "$jq_bin" --arg name "$_name" '.active = $name' "$subscription_file" >"$subscription_file.new" || return 1
  mv -f "$subscription_file.new" "$subscription_file"
}

update_active_subscription() {
  _active=$(active_subscription) || return 1
  _type=$("$jq_bin" -r --arg name "$_active" '.subscriptions[] | select(.name == $name) | .type' "$subscription_file")
  [ "$_type" = "remote" ] || { info "当前配置不是远程订阅，无需更新"; return 0; }
  _url=$("$jq_bin" -r --arg name "$_active" '.subscriptions[] | select(.name == $name) | .url // empty' "$subscription_file")
  _path=$("$jq_bin" -r --arg name "$_active" '.subscriptions[] | select(.name == $name) | .path // empty' "$subscription_file")
  case "$_url:$_path" in
    :*|*:) err "远程订阅缺少 url 或 path"; return 1 ;;
  esac
  case "$_path" in remote/*) ;; *) err "远程订阅 path 必须位于 remote/"; return 1 ;; esac
  case "$_path" in *'..'*|/*) err "远程订阅 path 无效"; return 1 ;; esac
  mkdir -p "$(dirname "$config_root/$_path")" || return 1
  download "$_url" "$config_root/$_path.new" || return 1
  "$jq_bin" -e . "$config_root/$_path.new" >/dev/null || {
    rm -f "$config_root/$_path.new"
    err "远程订阅不是有效 JSON"
    return 1
  }
  mv -f "$config_root/$_path.new" "$config_root/$_path"
  "$jq_bin" --arg name "$_active" --arg now "$(date '+%Y-%m-%d %H:%M:%S')" '
    .subscriptions |= map(if .name == $name then .updated_at = $now else . end)
  ' "$subscription_file" >"$subscription_file.new" || return 1
  mv -f "$subscription_file.new" "$subscription_file"
}

case "$1" in
  ensure) ensure_subscription_store ;;
  active) active_subscription ;;
  list) list_subscriptions ;;
  select)
    if [ -n "$2" ]; then
      select_subscription "$2"
    else
      err "用法: $0 select <name>"
      exit 2
    fi
    ;;
  update-active) update_active_subscription ;;
  *) echo "用法: $0 {ensure|active|list|select|update-active}" >&2; exit 2 ;;
esac

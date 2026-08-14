#!/system/bin/sh
# ============================================================
# sing-box for Android - 执行菜单
# 在 KernelSU / Magisk / APatch 管理器内点击模块的 [执行] 按钮时运行
# (Magisk 需要 27008+, APatch 需要 11039+, KernelSU 需要 10670+)
#
# 操作方式 (与常见模块一致):
#   音量下键  移动到下一个选项
#   音量上键  确认当前选项
#   5 分钟无按键自动退出
# ============================================================

# ---------- 环境初始化 ----------
MODDIR=${0%/*}
SCRIPTS_DIR="$MODDIR/scripts"
. "$SCRIPTS_DIR/lib.sh"

GETEVENT=$(command -v getevent 2>/dev/null || echo /system/bin/getevent)
TIMEOUT_BIN=$(command -v timeout 2>/dev/null || echo "")

# ============================================================
# 低层 UI 辅助
# ============================================================

# 读取音量键: 0=VOL+ 1=VOL- 2=超时 3=BACK(退出)
# 内部消费 UP 等无关事件, 避免一次按键导致菜单重复刷新
read_vol() {
  local line=""
  while :; do
    if [ -n "$TIMEOUT_BIN" ]; then
      line=$("$TIMEOUT_BIN" 5 "$GETEVENT" -qlc 1 2>/dev/null)
    else
      line=$("$GETEVENT" -qlc 1 2>/dev/null)
    fi
    case "$line" in
      *KEY_VOLUMEUP*DOWN*)   return 0 ;;
      *KEY_VOLUMEDOWN*DOWN*) return 1 ;;
      *KEY_BACK*DOWN*)       return 3 ;;
      "")                    return 2 ;;
      *) : ;; # UP 等其它事件, 忽略并继续读取
    esac
  done
}

# 清屏: 优先 clear 命令 (无 clear 的环境也能用换行滚屏达到刷新效果)
# Magisk 管理器终端不支持 ANSI 转义 (clear 会输出 \033[H\033[J 原文)
clear_screen() {
  if [ "${APATCH:-}" = "true" -o "${KSU:-}" = "true" ]; then
    if command -v clear >/dev/null 2>&1; then
      clear
    fi
  else
    echo ""
  fi
}

# 绘制菜单: 每次循环全量重绘 (参考 funbox 模块实现)
draw_menu() {
  local title=$1
  shift
  local i=1
  clear_screen
  echo "***************************************"
  echo "  sing-box for Android - 执行菜单"
  echo "  音量下键 移动   音量上键 确认"
  echo "***************************************"
  echo ""
  if service_running; then
    echo "  状态: 运行中"
  else
    echo "  状态: 未运行"
  fi
  if [ -f "$run_path/.config-changed" ]; then
    echo "  警告: 配置已修改，尚未重启"
  fi
  echo "  内核: $(cat "$sing_box_path/bin/kernel_version" 2>/dev/null || echo unknown) ($kernel_channel)"
  echo "---------------------------------------"
  echo ""
  echo "  --- $title ---"
  for opt in "$@"; do
    if [ "$i" -eq "$MENU_SEL" ]; then
      echo "-> $opt"
    else
      echo "  $opt"
    fi
    i=$((i + 1))
  done
  echo ""
  echo "***************************************"
}

# 交互选择: $1=标题, 其余=选项; 选择结果写入 MENU_SEL (1 起)
pick() {
  local title=$1
  shift
  MENU_SEL=1
  local max=$#
  local idle=0
  local redraw=1
  while true; do
    # 只在按键后重绘, 超时静默等待 (Magisk 用滚屏清屏, 超时重绘会每几秒自动滚动)
    if [ "$redraw" -eq 1 ]; then
      draw_menu "$title" "$@"
      redraw=0
    fi
    sleep 0.3
    read_vol
    case $? in
      1) # 音量下键: 移动到下一个选项
        MENU_SEL=$((MENU_SEL + 1))
        [ "$MENU_SEL" -gt "$max" ] && MENU_SEL=1
        idle=0
        redraw=1
        ;;
      0) # 音量上键: 确认
        echo ""
        return 0
        ;;
      2) # 超时
        idle=$((idle + 1))
        if [ "$idle" -ge 60 ]; then
          echo ""
          echo "[超时] 5 分钟未检测到按键, 已退出"
          exit 0
        fi
        ;;
      3) # 管理器返回键
        echo ""
        echo "已退出"
        exit 0
        ;;
      *) : ;; # 其它输入事件, 忽略
    esac
  done
}

# ============================================================
# 状态初始化
# ============================================================

autostart_status() {
  if autostart_enabled; then
    AUTOSTART_LABEL="禁用开机自启 (当前: 已启用)"
  else
    AUTOSTART_LABEL="启用开机自启 (当前: 已禁用)"
  fi
}

# ============================================================
# 具体动作
# ============================================================

# ---------- 后台执行操作, TUI 实时显示日志 ----------
# $1=标题, $2=日志名 (update=更新 / run=服务操作), 其余为命令及参数
run_op() {
  local title=$1
  local logname=$2
  shift 2
  local log="$run_path/$logname.log"
  local errlog="$run_path/${logname}_error.log"
  rotate_run_log
  : >"$log"
  : >"$errlog"
  echo ""
  echo "== 开始: $title =="
  nohup "$@" >>"$log" 2>>"$errlog" &
  local pid=$!
  local offset=0 size
  while kill -0 "$pid" 2>/dev/null; do
    size=$(wc -c <"$log" 2>/dev/null || echo 0)
    if [ "$size" -gt "$offset" ]; then
      tail -c +"$((offset + 1))" "$log" 2>/dev/null
      offset=$size
    fi
    sleep 1
  done
  wait "$pid"
  local rc=$?
  size=$(wc -c <"$log" 2>/dev/null || echo 0)
  if [ "$size" -gt "$offset" ]; then
    tail -c +"$((offset + 1))" "$log" 2>/dev/null
  fi
  if [ -s "$errlog" ]; then
    echo ""
    echo "[Error] --- ${logname}_error.log ---"
    tail -n 50 "$errlog"
  fi
  echo ""
  echo "== $title 结束 (退出码 $rc) =="
  return $rc
}

# ---------- 内核渠道切换 ----------
# 修改用户配置中的 kernel_channel 后执行更新
switch_channel() {
  local new_channel=$1
  local target="$CONFIG_DIR/sing-box.config"
  if [ ! -f "$target" ]; then
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    cp -f "$SCRIPTS_DIR/sing-box.config" "$target" 2>/dev/null
  fi
  sed -i "s/^kernel_channel=.*/kernel_channel=\"$new_channel\"/" "$target"
  echo "已切换渠道: $new_channel"
  echo "开始更新内核 ..."
  sh "$SCRIPTS_DIR/update_kernel.sh" "$new_channel" "$kernel_abi"
  echo "更新完成"
}

# ---------- 配置/订阅 ----------
SUBSCRIPTION_TOOL="$SCRIPTS_DIR/subscription.sh"
GOOGLE_FIREWALL_FIXER="$SCRIPTS_DIR/google-firewall-fixer.sh"
APP_LIST_TOOL="$SCRIPTS_DIR/app-list.sh"

select_config_menu() {
  local names name selected="" i=1 old_ifs
  names=$(sh "$SUBSCRIPTION_TOOL" list 2>/dev/null | cut -f1 | tr '\n' '|')
  [ -n "$names" ] || { echo "没有可选配置"; return; }

  old_ifs=$IFS
  IFS='|'
  set -f
  set -- $names
  set +f
  IFS=$old_ifs
  pick "选择当前配置" "$@" "返回上一级"
  [ "$MENU_SEL" -gt "$#" ] && return
  for name in "$@"; do
    if [ "$i" -eq "$MENU_SEL" ]; then
      selected=$name
      break
    fi
    i=$((i + 1))
  done
  if ! sh "$SUBSCRIPTION_TOOL" select "$selected"; then
    return
  fi
  echo "已选择配置: $selected"
  run_op "应用配置" run sh "$SCRIPTS_DIR/sing-box.service" restart
}

config_menu() {
  while true; do
    local active
    active=$(sh "$SUBSCRIPTION_TOOL" active 2>/dev/null || echo unknown)
    pick \
      "配置管理 (当前: $active)" \
      "选择当前配置 ..." \
      "更新当前远程订阅" \
      "更新预置代理应用名单" \
      "返回上一级"
    case "$MENU_SEL" in
      1) select_config_menu ;;
      2)
        if run_op "更新当前远程订阅" update sh "$SUBSCRIPTION_TOOL" update-active; then
          run_op "应用配置" run sh "$SCRIPTS_DIR/sing-box.service" restart
        fi
        ;;
      3)
        if run_op "更新预置代理应用名单" update sh "$APP_LIST_TOOL" update-proxy-package-list; then
          run_op "应用分流设置" run sh "$SCRIPTS_DIR/sing-box.service" restart
        fi
        ;;
      4) return ;;
    esac
  done
}

# ============================================================
# 子菜单与主菜单
# ============================================================

# ---------- 内核更新子菜单 ----------
kernel_menu() {
  while true; do
    pick \
      "内核更新" \
      "更新内核 (当前渠道: $kernel_channel)" \
      "切换到 reF1nd pre-release ..." \
      "切换到 reF1nd stable ..." \
      "切换到 官方 stable ..." \
      "切换到 官方 pre-release ..." \
      "返回上一级"
    case "$MENU_SEL" in
      1) run_op "更新内核" update sh "$SCRIPTS_DIR/update_kernel.sh" "$kernel_channel" "$kernel_abi" ;;
      2) switch_channel refind-pre ;;
      3) switch_channel refind-stable ;;
      4) switch_channel official-stable ;;
      5) switch_channel official-pre ;;
      6) return ;;
    esac
  done
}

# ---------- 主菜单 (循环, 退出选项结束) ----------
main_menu() {
  while true; do
    load_config
    autostart_status
    pick \
      "请选择操作" \
      "启动 sing-box" \
      "停止 sing-box" \
      "重启 sing-box" \
      "配置管理 ..." \
      "更新内核 ..." \
      "清理 Google 服务拦截规则" \
      "$AUTOSTART_LABEL" \
      "退出"
    case "$MENU_SEL" in
      1) run_op "启动 sing-box" run sh "$SCRIPTS_DIR/sing-box.service" start ;;
      2) run_op "停止 sing-box" run sh "$SCRIPTS_DIR/sing-box.service" stop ;;
      3) run_op "重启 sing-box" run sh "$SCRIPTS_DIR/sing-box.service" restart ;;
      4) config_menu ;;
      5) kernel_menu ;;
      6) run_op "清理 Google 服务拦截规则" run sh "$GOOGLE_FIREWALL_FIXER" apply ;;
      7) echo ""; toggle_autostart ;;
      8) break ;;
    esac
  done
}

# ============================================================
# 启动入口
# ============================================================
load_config
main_menu

echo ""
echo "完成。"

#!/sbin/sh
# ============================================================
# sing-box for Android - 安装脚本
# 由 Magisk / KernelSU / APatch (APM) 安装器在解压并设置默认权限后 source
# 参考:
#   https://topjohnwu.github.io/Magisk/guides.html
#   https://kernelsu.org/guide/module.html
#   https://apatch.dev/apm-guide.html
# ============================================================

# 仅支持在管理器内安装 (需要 root 初始化数据目录)
if [ "$BOOTMODE" != "true" ]; then
  abort "! 请使用 Magisk/KernelSU 管理器安装本模块"
fi

# 执行按钮 (action.sh) 最低管理器版本要求:
#   Magisk >= 27008 (canary 27008 首次加入 action.sh 支持)
#   KernelSU >= 10670
#   APatch >= 11039 (首次加入 action.sh 支持)
if [ "${APATCH:-}" = "true" ]; then
  if [ "${APATCH_VER_CODE:-0}" -lt 11039 ]; then
    abort "! 请升级 APatch 后再安装 (执行按钮需要 APatch >= 11039)"
  fi
elif [ "${KSU:-}" = "true" ]; then
  if [ "${KSU_VER_CODE:-0}" -lt 10670 ]; then
    abort "! 请升级 KernelSU 后再安装 (执行按钮需要 >= 10670)"
  fi
else
  if [ "${MAGISK_VER_CODE:-0}" -lt 27008 ]; then
    abort "! 请升级 Magisk 后再安装 (执行按钮需要 Magisk >= 27008)"
  fi
fi

# 公共函数库
. "$MODPATH/scripts/lib.sh"

DATA_DIR=/data/adb/sing-box_module
BIN_DIR=$DATA_DIR/bin
USER_SCRIPTS_DIR=$DATA_DIR/scripts
CONFIG_DIR=$DATA_DIR/config
LOCAL_CONFIG_DIR=$CONFIG_DIR/local
REMOTE_CONFIG_DIR=$CONFIG_DIR/remote
INBOUNDS_DIR=$CONFIG_DIR/inbounds
INBOUND_TEMPLATE_DIR=$INBOUNDS_DIR/tpl
RUNTIME_CONFIG_DIR=$CONFIG_DIR/run
RUN_DIR=$DATA_DIR/run

ui_print "- 初始化运行时目录 $DATA_DIR"
mkdir -p "$BIN_DIR" "$USER_SCRIPTS_DIR" "$LOCAL_CONFIG_DIR" "$REMOTE_CONFIG_DIR" "$INBOUNDS_DIR" "$INBOUND_TEMPLATE_DIR" "$RUNTIME_CONFIG_DIR" "$RUN_DIR"

# 音量键交互: 检测到已有二进制时询问是否用包内新版本覆盖
# 0=音量+ 覆盖  1=音量-/超时 跳过
GETEVENT=$(command -v getevent 2>/dev/null || echo /system/bin/getevent)
TIMEOUT_BIN=$(command -v timeout 2>/dev/null || echo "")

ask_cover_bin() {
  ui_print "- 音量+ 覆盖 / 其他键 跳过 (5 秒无按键自动跳过)"
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
      "")                    return 1 ;;
      *) : ;; # UP 等无关事件, 忽略并继续读取
    esac
  done
}

# 记住包内是否携带规则组件；稍后会删除模块内的临时载荷目录。
HAS_TPROXY=0
[ -f "$MODPATH/sing-box/bin/atp" ] && HAS_TPROXY=1

# 内置二进制: 全新安装直接拷贝; 升级时询问是否覆盖
if [ ! -f "$BIN_DIR/sing-box" ]; then
  ui_print "- 首次安装: 拷贝内置二进制"
  cp -rf "$MODPATH/sing-box/bin/." "$BIN_DIR/"
else
  ui_print "- 检测到已有二进制"
  if ask_cover_bin; then
    ui_print "- 已选择覆盖: 用包内二进制覆盖现有版本"
    cp -rf "$MODPATH/sing-box/bin/." "$BIN_DIR/"
  else
    ui_print "- 已选择跳过: 保留现有二进制"
    ui_print "- 内核更新请使用管理器内的 [执行] 按钮"
    ui_print "- 或在管理器内打开 WebUI 更新页面"
  fi
fi

# Upgrade path: users may retain the existing core but have no atp yet.
if [ "$HAS_TPROXY" = "1" ] && [ ! -f "$BIN_DIR/atp" ]; then
  cp -f "$MODPATH/sing-box/bin/atp" "$BIN_DIR/atp"
  chmod 755 "$BIN_DIR/atp"
  cp -f "$MODPATH/sing-box/bin/atp_version" "$BIN_DIR/atp_version" 2>/dev/null || true
fi
rm -rf "$MODPATH/sing-box"

# 配置文件: 保留用户已有配置
if [ ! -f "$USER_SCRIPTS_DIR/sing-box.config" ]; then
  ui_print "- 写入默认配置文件 sing-box.config"
  cp -f "$MODPATH/scripts/sing-box.config" "$USER_SCRIPTS_DIR/sing-box.config"
  # 按设备架构设置默认 ABI
  ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
  case "$ABI" in
    arm64-v8a|armeabi-v7a|x86_64|x86)
      sed -i "s/^kernel_abi=.*/kernel_abi=\"$ABI\"/" "$USER_SCRIPTS_DIR/sing-box.config"
      ui_print "- 已按设备架构设置 kernel_abi=$ABI"
      ;;
    *) ui_print "! 无法识别设备 ABI ($ABI), 保持默认 arm64-v8a" ;;
  esac
fi

# 默认完整配置与订阅索引。之后由 action/WebUI 切换 active 项。
if [ ! -f "$LOCAL_CONFIG_DIR/default.json" ]; then
  ui_print "- 写入默认完整配置 local/default.json"
  cp -f "$MODPATH/scripts/config.json.tpl" "$LOCAL_CONFIG_DIR/default.json"
fi
if [ ! -f "$USER_SCRIPTS_DIR/subscription.json" ]; then
  ui_print "- 写入订阅索引 subscription.json"
  printf '%s\n' '{' \
    '  "active": "default",' \
    '  "subscriptions": [' \
    '    {"name":"default","type":"local","filename":"default.json","url":null,"updated_at":null}' \
    '  ]' \
    '}' >"$USER_SCRIPTS_DIR/subscription.json"
fi

# 入站模板位于 config/inbounds/tpl；用户可在 config/inbounds/ 放置同名 JSON 覆盖。
for INBOUND_TEMPLATE in "$MODPATH"/config/inbounds/tpl/*.json; do
  [ -f "$INBOUND_TEMPLATE" ] || continue
  INBOUND_TARGET="$INBOUND_TEMPLATE_DIR/$(basename "$INBOUND_TEMPLATE")"
  [ -f "$INBOUND_TARGET" ] || cp -f "$INBOUND_TEMPLATE" "$INBOUND_TARGET"
done

# AndroidTProxyShell (atp, 透明代理 iptables 规则): 配置模板 + 缺失兜底
# atp 脚本随内置二进制一起拷贝 (首次/覆盖时); 此处仅补缺失 (旧版升级无 atp 时)
# tproxy.conf 与 sing-box.config 同在用户 scripts/，首次安装写入，升级保留。
if [ ! -f "$USER_SCRIPTS_DIR/tproxy.conf" ]; then
  ui_print "- 写入默认配置 tproxy.conf"
  cp -f "$MODPATH/scripts/tproxy.conf" "$USER_SCRIPTS_DIR/tproxy.conf"
fi
if [ ! -f "$USER_SCRIPTS_DIR/force_proxy_app.txt" ]; then
  ui_print "- 写入强制代理应用配置"
  cp -f "$MODPATH/scripts/force_proxy_app.txt" "$USER_SCRIPTS_DIR/force_proxy_app.txt"
fi
if [ ! -f "$USER_SCRIPTS_DIR/force_bypass_app.txt" ]; then
  ui_print "- 写入强制白名单配置"
  cp -f "$MODPATH/scripts/force_bypass_app.txt" "$USER_SCRIPTS_DIR/force_bypass_app.txt"
fi
if [ ! -f "$CONFIG_DIR/proxy_package_name" ]; then
  if [ -f "$MODPATH/config/proxy_package_name" ]; then
    ui_print "- 写入预置代理应用名单"
    cp -f "$MODPATH/config/proxy_package_name" "$CONFIG_DIR/proxy_package_name"
  else
    ui_print "! 模块未携带名单，启用自动生成前请在 [执行] 菜单更新"
  fi
fi

# 权限
set_perm_recursive "$MODPATH" 0 0 0755 0644
chmod 755 "$BIN_DIR/sing-box" 2>/dev/null
set_perm "$USER_SCRIPTS_DIR/sing-box.config" 0 0 0600
set_perm "$USER_SCRIPTS_DIR/tproxy.conf" 0 0 0600
set_perm "$USER_SCRIPTS_DIR/force_proxy_app.txt" 0 0 0600
set_perm "$USER_SCRIPTS_DIR/force_bypass_app.txt" 0 0 0600
set_perm "$USER_SCRIPTS_DIR/subscription.json" 0 0 0600
chmod ugo+x "$MODPATH"/*.sh "$MODPATH"/scripts/*.sh "$MODPATH"/scripts/sing-box.service "$MODPATH"/scripts/sing-box.inotify "$MODPATH"/scripts/config.inotify "$MODPATH"/scripts/net.inotify 2>/dev/null

ui_print "- 安装完成"
ui_print "- 重启后 sing-box 将自动启动"
ui_print "- 管理器内点击 [执行] 可按音量键选择操作"
ui_print "- 内核渠道默认 refind-pre, 可在 [执行] 菜单切换"

#!/system/bin/sh
# ============================================================
# sing-box for Android - 内核更新脚本
# 从指定渠道下载 sing-box 二进制并原子替换。
#
# 渠道 (channel):
#   refind-pre         reF1nd/sing-box-releases 最新 pre-release (默认)
#   refind-stable      reF1nd/sing-box-releases 最新稳定版
#   official-stable    SagerNet/sing-box 最新稳定版
#   official-pre       SagerNet/sing-box 最新 pre-release
#
# 用法:
#   update_kernel.sh [channel] [abi]
#     channel  渠道名 (默认读配置或 refind-pre)
#     abi      arm64-v8a | armeabi-v7a | x86_64 | x86 (默认读配置或 arm64-v8a)
#
# 环境变量:
#   SING_BOX_KERNEL_DIR   二进制安装目录 (默认 <data_dir>/bin)
#   NO_RESTART=1          更新后不重启服务 (由调用方统一重启)
#   SKIP_VERSION_CHECK=1  跳过"已是最新"判断, 强制重新下载
#
# 退出码:
#   0 成功 (含已是最新)  1 下载/校验失败  2 参数错误
# ============================================================

# ---------- 基础工具 (不依赖 lib.sh, 可独立运行) ----------
info() { echo "[Info] $1"; }
warn() { echo "[Warn] $1"; }
err()  { echo "[Error] $1"; }

# curl 优先, 回退 wget
download() {  # $1=url  $2=输出文件
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 600 --retry 3 --retry-delay 2 --retry-max-time 60 "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    err "未找到 curl / wget, 无法下载"
    return 127
  fi
}

fetch_text() {  # $1=url
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 30 "$1" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1" 2>/dev/null
  fi
}

# ---------- ABI 映射 (Android ABI -> sing-box / jq 资产 arch) ----------
singbox_arch() {  # $1=abi
  case "$1" in
    arm64-v8a)   echo arm64 ;;
    armeabi-v7a) echo arm ;;
    x86_64)      echo amd64 ;;
    x86)         echo 386 ;;
    *)           echo "" ;;
  esac
}

jq_arch() {  # $1=abi  (jq-android-build 资产命名)
  case "$1" in
    arm64-v8a)   echo arm64 ;;
    armeabi-v7a) echo arm ;;
    x86_64)      echo x64 ;;
    x86)         echo ia32 ;;
    *)           echo "" ;;
  esac
}

# 优先使用内置 jq (jq-android-build 静态链接, 与模块一起分发), 回退系统 jq
find_jq() {
  if [ -x "$KERNEL_DIR/jq" ]; then
    echo "$KERNEL_DIR/jq"
  elif command -v jq >/dev/null 2>&1; then
    echo "jq"
  fi
}
JQ=$(find_jq)

# ---------- 配置加载 ----------
# 优先环境变量, 其次用户配置 (/data/adb/sing-box_module/config), 最后模块内置默认
DATA_DIR=/data/adb/sing-box_module
CONFIG_DIR=$DATA_DIR/scripts
SCRIPTS_DIR=$(dirname "$0")

KERNEL_DIR="${SING_BOX_KERNEL_DIR:-$DATA_DIR/bin}"
CHANNEL="${1:-}"
ABI="${2:-}"

if [ -z "$CHANNEL" ] || [ -z "$ABI" ]; then
  # 从配置读取默认值 (配置不存在时用内置默认)
  if [ -f "$CONFIG_DIR/sing-box.config" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_DIR/sing-box.config" 2>/dev/null
  elif [ -f "$SCRIPTS_DIR/sing-box.config" ]; then
    # shellcheck disable=SC1090
    . "$SCRIPTS_DIR/sing-box.config" 2>/dev/null
  fi
  [ -z "$CHANNEL" ] && CHANNEL="${kernel_channel:-refind-pre}"
  [ -z "$ABI" ] && ABI="${kernel_abi:-arm64-v8a}"
fi

case "$CHANNEL" in
  delusions6515-pre|delusions6515-stable|refind-pre|refind-stable|official-stable|official-pre) : ;;
  *) err "未知渠道: $CHANNEL (delusions6515-pre|delusions6515-stable|refind-pre|refind-stable|official-stable|official-pre)"; exit 2 ;;
esac

ARCH=$(singbox_arch "$ABI")
if [ -z "$ARCH" ]; then
  err "不支持的 ABI: $ABI (arm64-v8a|armeabi-v7a|x86_64|x86)"
  exit 2
fi

# ---------- 渠道 -> 仓库 ----------
case "$CHANNEL" in
  delusions6515-*)  REPO="Delusions6515/sing-box-releases";;
  refind-*)         REPO="reF1nd/sing-box-releases" ;;
  official-*)       REPO="SagerNet/sing-box" ;;
esac
# pre-release 渠道: 1=取最新 pre-release; 0=取最新稳定版
case "$CHANNEL" in
  *-pre)   WANT_PRE=1 ;;
  *-stable) WANT_PRE=0 ;;
esac

# ---------- 获取最新版本号 ----------
# stable: GitHub 重定向 /releases/latest -> /releases/tag/<tag>, 免 API 限流
# pre:    通过 API 列 release 找第一个 prerelease (列表按创建时间倒序)
latest_tag() {  # $1=repo  $2=want_pre (0/1)
  local repo="$1" want_pre="$2" tag="" url=""
  if [ "$want_pre" = "0" ]; then
    url=$(curl -sI -o /dev/null -w '%{redirect_url}' --max-time 30 \
      "https://github.com/$repo/releases/latest" 2>/dev/null)
    tag=$(basename "$url" 2>/dev/null)
    [ "$tag" != "latest" ] && [ -n "$tag" ] && { echo "$tag"; return 0; }
    # 回退: API
    tag=$(fetch_text "https://api.github.com/repos/$repo/releases/latest" \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  elif [ -n "$JQ" ]; then
    # 列表按发布时间倒序, 第一个 prerelease=true 的 tag
    tag=$(fetch_text "https://api.github.com/repos/$repo/releases?per_page=100" \
      | "$JQ" -r '[.[] | select(.prerelease == true) | .tag_name][0]' 2>/dev/null)
  else
    # 无 jq 回退: tag_name 与 prerelease 字段成对出现, 逐条配对
    # (GitHub API 返回单行紧凑 JSON, 不能用 awk 跨行状态机; .* 贪婪匹配会取到最后一条)
    tag=$(fetch_text "https://api.github.com/repos/$repo/releases?per_page=100" \
      | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"|"prerelease"[[:space:]]*:[[:space:]]*(true|false)' \
      | while read -r _line; do
          case "$_line" in
            *tag_name*) _t=$(printf '%s' "$_line" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p') ;;
            *prerelease*true*) [ -n "$_t" ] && { echo "$_t"; break; } ;;
          esac
        done)
  fi
  echo "$tag"
}

TAG=$(latest_tag "$REPO" "$WANT_PRE")
if [ -z "$TAG" ]; then
  err "无法获取 $CHANNEL ($REPO) 的最新版本号"
  exit 1
fi
VER=${TAG#v}

# 资产命名 (两仓库规则一致): sing-box-<ver>-android-<arch>.tar.gz
ASSET="sing-box-${VER}-android-${ARCH}.tar.gz"
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"

info "渠道: $CHANNEL ($REPO)"
info "最新版本: $VER"
info "架构: $ABI -> $ARCH"

# ---------- 新旧版本比对 ----------
BIN="$KERNEL_DIR/sing-box"
VER_FILE="$KERNEL_DIR/kernel_version"
mkdir -p "$KERNEL_DIR"

if [ "${SKIP_VERSION_CHECK:-0}" != "1" ] && [ -f "$BIN" ] && [ -f "$VER_FILE" ]; then
  CURRENT=$(cat "$VER_FILE" 2>/dev/null)
  if [ "$CURRENT" = "$VER" ]; then
    info "已是最新版本 ($VER), 无需更新"
    exit 0
  fi
  info "当前版本: $CURRENT"
fi

# ---------- 下载 + 解包 + 校验 ----------
TMP_DIR=$(mktemp -d "$KERNEL_DIR/.update.XXXXXX" 2>/dev/null || mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

info "下载 $ASSET ..."
if ! download "$URL" "$TMP_DIR/$ASSET"; then
  err "下载失败: $URL"
  exit 1
fi

info "解包 ..."
if ! tar -xzf "$TMP_DIR/$ASSET" -C "$TMP_DIR" 2>/dev/null; then
  err "解包失败 (文件可能不完整)"
  exit 1
fi

NEW_BIN=$(find "$TMP_DIR" -type f -name sing-box | head -n 1)
if [ -z "$NEW_BIN" ]; then
  err "解包后未找到 sing-box 可执行文件"
  exit 1
fi

# 可执行性 + 版本字符串校验 (Android 上运行真实 sing-box 验证)
chmod 755 "$NEW_BIN" 2>/dev/null
VERSION_OUT=$("$NEW_BIN" version 2>/dev/null | head -n 1)
if [ -z "$VERSION_OUT" ]; then
  err "二进制校验失败: 无法执行 sing-box version"
  exit 1
fi
info "版本输出: $VERSION_OUT"

# ---------- 原子替换 ----------
# 先写 .new 再 mv: 避免更新到一半进程读到残缺文件
cp -f "$NEW_BIN" "$BIN.new" 2>/dev/null || { err "写入 $BIN.new 失败"; exit 1; }
chmod 755 "$BIN.new"
mv -f "$BIN" "$BIN.old" 2>/dev/null
mv -f "$BIN.new" "$BIN"
echo "$VER" > "$VER_FILE"
info "内核已更新到 $VER"

# ---------- 重启 ----------
if [ "${NO_RESTART:-0}" != "1" ]; then
  info "重启服务 ..."
  if [ -f "$SCRIPTS_DIR/sing-box.service" ]; then
    sh "$SCRIPTS_DIR/sing-box.service" restart
  fi
fi

info "完成"
exit 0

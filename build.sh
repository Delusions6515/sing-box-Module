#!/bin/bash
# ============================================================
# sing-box for Android - 模块构建脚本
# 内核二进制从指定渠道在线获取并内置进模块 zip, 可直接在 GitHub Actions 中运行。
#
# 用法:
#   ./build.sh                 # 版本名取最近 git tag (如 v1.0.0), 默认 arm64-v8a / refind-pre
#   ./build.sh 1.0.0           # 指定版本名覆盖 tag
#   ./build.sh 1.0.0 out.zip   # 指定版本名和输出路径
#
# 版本命名参考 ZygiskNext (module.prop 中为占位符, 不硬编码):
#   version=1.0.0 (<git提交数>-<短hash>-release)
#   versionCode=<git提交数>
#
# 环境变量:
#   TARGET_ABI      目标 ABI: arm64-v8a(默认)|armeabi-v7a|x86_64|x86
#   KERNEL_CHANNEL  内核渠道: refind-pre(默认)|refind-stable|official-stable|official-pre
#   OUT_DIR         输出目录 (默认 ./build)
#   SKIP_VERSION_CHECK  设为 1 跳过新旧版本对比 (强制重新下载)
#
# 依赖: curl, unzip, zip, python3 (可选, 版本号解析)
# ============================================================
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
MODULE_DIR="$REPO_DIR/module"
OUT_DIR="${OUT_DIR:-$(pwd)/build}"
TARGET_ABI="${TARGET_ABI:-arm64-v8a}"
KERNEL_CHANNEL="${KERNEL_CHANNEL:-delusions6515-pre}"
VERSION="${1:-}"
OUT_ZIP="${2:-}"

info() { echo "[*] $1"; }
warn() { echo "[!] $1"; }
die()  { echo "[Error] $1"; exit 1; }

download() {  # $1=url $2=输出文件
  curl -fsSL --connect-timeout 10 --max-time 600 --retry 3 --retry-delay 2 --retry-max-time 60 "$1" -o "$2"
}

# GitHub API 获取 (优先 GITHUB_TOKEN 认证避免限流, 其次 gh CLI, 最后匿名)
api_get() {  # $1=api path
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL --max-time 30 -H "Authorization: Bearer $GITHUB_TOKEN" "https://api.github.com$1" 2>/dev/null
  elif command -v gh >/dev/null 2>&1; then
    gh api "$1" 2>/dev/null
  else
    curl -fsSL --max-time 30 "https://api.github.com$1" 2>/dev/null
  fi
}

# ---------- ABI 映射 ----------
case "$TARGET_ABI" in
  arm64-v8a)   SINGBOX_ARCH="arm64"; JQ_ARCH="arm64" ;;
  armeabi-v7a) SINGBOX_ARCH="arm";    JQ_ARCH="arm" ;;
  x86_64)      SINGBOX_ARCH="amd64";  JQ_ARCH="x64" ;;
  x86)         SINGBOX_ARCH="386";    JQ_ARCH="ia32" ;;
  *) die "不支持的 TARGET_ABI: $TARGET_ABI (arm64-v8a|armeabi-v7a|x86_64|x86)" ;;
esac
info "目标 ABI: $TARGET_ABI (sing-box: $SINGBOX_ARCH, jq: $JQ_ARCH)  渠道: $KERNEL_CHANNEL"

# ---------- 渠道 -> 仓库 ----------
case "$KERNEL_CHANNEL" in
  delusions6515-*)  KERNEL_REPO="Delusions6515/sing-box-releases";;
  refind-*)         KERNEL_REPO="reF1nd/sing-box-releases" ;;
  official-*)       KERNEL_REPO="SagerNet/sing-box" ;;
  *) die "不支持的 KERNEL_CHANNEL: $KERNEL_CHANNEL (delusions6515-pre|delusions6515-stable|refind-pre|refind-stable|official-stable|official-pre)" ;;
esac
case "$KERNEL_CHANNEL" in
  *-pre)     WANT_PRE=1 ;;
  *-stable)  WANT_PRE=0 ;;
esac

# ---------- 获取最新版本号 ----------
latest_tag() {  # $1=repo  $2=want_pre
  local repo="$1" want_pre="$2" tag="" url=""
  if [ "$want_pre" = "0" ]; then
    url=$(curl -sI -o /dev/null -w '%{redirect_url}' --max-time 30 \
      "https://github.com/$repo/releases/latest" 2>/dev/null)
    tag=$(basename "$url" 2>/dev/null)
    [ "$tag" != "latest" ] && [ -n "$tag" ] && { echo "$tag"; return 0; }
    tag=$(api_get "/repos/$repo/releases/latest" \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  elif [ "$want_pre" = "1" ] && command -v jq >/dev/null 2>&1; then
    # 列表按发布时间倒序, 第一个 prerelease=true 的 tag
    tag=$(api_get "/repos/$repo/releases?per_page=100" \
      | jq -r '[.[] | select(.prerelease == true) | .tag_name][0]' 2>/dev/null)
  else
    # 无 jq 回退: tag_name 与 prerelease 字段成对出现, 逐条配对
    # (GitHub API 返回单行紧凑 JSON, 不能用 awk 跨行状态机; .* 贪婪匹配会取到最后一条)
    tag=$(api_get "/repos/$repo/releases?per_page=100" \
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

TAG=$(latest_tag "$KERNEL_REPO" "$WANT_PRE")
[ -n "$TAG" ] || die "无法获取 $KERNEL_CHANNEL ($KERNEL_REPO) 的最新版本号"
KERNEL_VER=${TAG#v}
info "内核版本: $KERNEL_VER"

# ---------- 1. 拷贝模块源码 ----------
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -r "$MODULE_DIR/." "$STAGE/"
find "$STAGE" -name .DS_Store -delete

# ---------- 预置代理应用名单 ----------
# 仅写入构建暂存目录，不将上游名单提交到仓库。
PROXY_PACKAGE_LIST_URL="https://raw.githubusercontent.com/2dust/v2rayNG/master/V2rayNG/app/src/main/assets/proxy_package_name"
info "下载预置代理应用名单 ..."
mkdir -p "$STAGE/config"
if download "$PROXY_PACKAGE_LIST_URL" "$STAGE/config/proxy_package_name.tmp" \
  && awk '$0 ~ /^[A-Za-z][A-Za-z0-9_.]*$/ { found = 1 } END { exit !found }' "$STAGE/config/proxy_package_name.tmp"; then
  mv -f "$STAGE/config/proxy_package_name.tmp" "$STAGE/config/proxy_package_name"
else
  rm -f "$STAGE/config/proxy_package_name.tmp"
  warn "代理应用名单下载失败，自动生成分应用名单不可用"
fi

# ---------- 2. 组件 (内核 + jq 二进制, 均内置) ----------
# 组件目录 $REPO_DIR/bin (含版本文件); 构建优先使用, 缺失/过旧自动下载
BIN_DIR="$REPO_DIR/bin"
STAGE_BIN="$STAGE/sing-box/bin"
mkdir -p "$BIN_DIR" "$STAGE_BIN"

# --- jq (设备端 JSON 解析, jq-android-build 静态链接) ---
JQ_BIN="$BIN_DIR/jq"
JQ_VER_FILE="$BIN_DIR/jq_version"
JQ_VER="1.8.2"
JQ_CURRENT=""
[ -f "$JQ_VER_FILE" ] && JQ_CURRENT=$(cat "$JQ_VER_FILE")
if [ ! -f "$JQ_BIN" ] || [ "$JQ_CURRENT" != "$JQ_VER" ]; then
  info "下载 jq $JQ_VER ($JQ_ARCH) ..."
  JQ_TMP=$(mktemp -d)
  download "https://github.com/Delusions6515/jq-android-build/releases/download/jq-android-${JQ_ARCH}-1.8/jq-android-${JQ_ARCH}-${JQ_VER}.tar.xz" "$JQ_TMP/jq.tar.xz"
  tar -xJf "$JQ_TMP/jq.tar.xz" -C "$JQ_TMP"
  JQ_NEW=$(find "$JQ_TMP" -type f -name jq | head -n 1)
  [ -n "$JQ_NEW" ] || die "解包后未找到 jq 可执行文件"
  cp -f "$JQ_NEW" "$JQ_BIN"
  chmod 755 "$JQ_BIN"
  echo "$JQ_VER" > "$JQ_VER_FILE"
  rm -rf "$JQ_TMP"
  info "jq: $JQ_VER"
else
  info "jq: 使用缓存 $JQ_VER"
fi

# --- AndroidTProxyShell (透明代理 iptables 规则) ---
# 无 release 机制, 按 main 分支最新 commit 下载, commit sha 作版本号
# 脚本下载后命名为 atp (参考 AndroidTProxyShell README 的惯例), 与内核/jq 一起放 bin/
TPROXY_SRC="https://raw.githubusercontent.com/CHIZI-0618/AndroidTProxyShell/main/tproxy.sh"
TPROXY_BIN="$BIN_DIR/atp"
TPROXY_VER_FILE="$BIN_DIR/atp_version"
TPROXY_VER=""
TPROXY_CURRENT=""
[ -f "$TPROXY_VER_FILE" ] && TPROXY_CURRENT=$(cat "$TPROXY_VER_FILE")
TPROXY_VER=$(api_get "/repos/CHIZI-0618/AndroidTProxyShell/commits/main" \
  | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
TPROXY_VER=${TPROXY_VER:0:7}
if [ -z "$TPROXY_VER" ]; then
  warn "无法获取 AndroidTProxyShell 版本号, 跳过版本对比"
elif [ ! -f "$TPROXY_BIN" ] || [ "$TPROXY_CURRENT" != "$TPROXY_VER" ]; then
  mkdir -p "$(dirname "$TPROXY_BIN")"
  info "下载 AndroidTProxyShell $TPROXY_VER ..."
  if download "$TPROXY_SRC" "$TPROXY_BIN.tmp"; then
    mv -f "$TPROXY_BIN.tmp" "$TPROXY_BIN"
    chmod 755 "$TPROXY_BIN"
    echo "$TPROXY_VER" > "$TPROXY_VER_FILE"
    info "atp: $TPROXY_VER"
  else
    rm -f "$TPROXY_BIN.tmp"
    warn "atp 下载失败, 跳过 (透明代理规则将不可用)"
  fi
else
  info "atp: 使用缓存 $TPROXY_VER"
fi

# --- sing-box 内核 ---
KERNEL_BIN="$BIN_DIR/sing-box"
KERNEL_VER_FILE="$BIN_DIR/kernel_version"
current=""
[ -f "$KERNEL_VER_FILE" ] && current=$(cat "$KERNEL_VER_FILE")

need_fetch=0
if [ ! -f "$KERNEL_BIN" ]; then
  need_fetch=1
elif [ "${SKIP_VERSION_CHECK:-0}" != "1" ] && [ "$current" != "$KERNEL_VER" ]; then
  warn "版本检查: 内核过旧 (bin=${current:-无}, 最新=$KERNEL_VER), 重新下载"
  need_fetch=1
fi

if [ "$need_fetch" = "1" ]; then
  info "下载 sing-box $KERNEL_VER ($SINGBOX_ARCH) ..."
  ASSET="sing-box-${KERNEL_VER}-android-${SINGBOX_ARCH}.tar.gz"
  URL="https://github.com/$KERNEL_REPO/releases/download/$TAG/$ASSET"
  TMP=$(mktemp -d)
  download "$URL" "$TMP/$ASSET"
  tar -xzf "$TMP/$ASSET" -C "$TMP"
  NEW_BIN=$(find "$TMP" -type f -name sing-box | head -n 1)
  [ -n "$NEW_BIN" ] || die "解包后未找到 sing-box 可执行文件"
  cp -f "$NEW_BIN" "$KERNEL_BIN"
  chmod 755 "$KERNEL_BIN"
  echo "$KERNEL_VER" > "$KERNEL_VER_FILE"
  rm -rf "$TMP"
  info "内核: $KERNEL_VER"
else
  info "内核: 使用缓存 $KERNEL_VER"
fi

# 同步到 stage
cp -rf "$BIN_DIR/." "$STAGE_BIN/"
chmod 755 "$STAGE_BIN/sing-box" "$STAGE_BIN/jq" "$STAGE_BIN/atp" 2>/dev/null
[ -e "$STAGE_BIN/sing-box" ] || die "缺少内核二进制"
[ -e "$STAGE_BIN/jq" ] || die "缺少 jq 二进制"

# ---------- 3. META-INF (官方 module_installer.sh), 失败则跳过 ----------
mkdir -p "$STAGE/META-INF/com/google/android"
if download "https://raw.githubusercontent.com/topjohnwu/Magisk/master/scripts/module_installer.sh" \
  "$STAGE/META-INF/com/google/android/update-binary"; then
  printf '#MAGISK\n' > "$STAGE/META-INF/com/google/android/updater-script"
  info "已获取官方 module_installer.sh (支持恢复模式刷入)"
else
  rm -rf "$STAGE/META-INF"
  warn "获取 module_installer.sh 失败, 跳过 META-INF (管理器内安装不受影响)"
fi

# ---------- 4. 版本 (参考 ZygiskNext: versionCode=git 提交数, version 附带短 hash) ----------
VER_NAME="${VERSION:-}"
if [ -z "$VER_NAME" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  VER_NAME=$(git describe --tags --exact-match HEAD 2>/dev/null \
    || git describe --tags --abbrev=0 2>/dev/null || true)
fi
VER_NAME="${VER_NAME:-dev}"
VER_NAME="${VER_NAME#v}"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  VER_CODE=$(git rev-list HEAD --count 2>/dev/null || echo 1)
  VER_HASH=$(git rev-parse --verify --short HEAD 2>/dev/null || echo unknown)
else
  warn "不在 git 仓库中, versionCode 回退为 1"
  VER_CODE=1
  VER_HASH="nogit"
fi
BUILD_TYPE="${BUILD_TYPE:-release}"
VERSION_LINE="$VER_NAME ($VER_CODE-$VER_HASH-$BUILD_TYPE)"
sed -i "s/^version=.*/version=$VERSION_LINE/; s/^versionCode=.*/versionCode=$VER_CODE/" "$STAGE/module.prop"
info "版本: $VERSION_LINE (versionCode: $VER_CODE)"

# ---------- 5. updateJson (各架构分开, 由 workflow 发布到 gh-pages 分支) ----------
UPDATE_JSON_BASE="${UPDATE_JSON_BASE:-https://raw.githubusercontent.com/Delusions6515/sing-box-Module/gh-pages}"
sed -i "/^updateJson=/d" "$STAGE/module.prop"
echo "updateJson=$UPDATE_JSON_BASE/update-${TARGET_ABI}.json" >> "$STAGE/module.prop"
info "updateJson: $UPDATE_JSON_BASE/update-${TARGET_ABI}.json"

# ---------- 6. 权限 ----------
find "$STAGE" -type f \( -name '*.sh' -o -name 'sing-box.service' -o -name 'sing-box.inotify' -o -name 'config.inotify' -o -name 'update-binary' \) -exec chmod 755 {} +
find "$STAGE" -type d -exec chmod 755 {} +
chmod 755 "$STAGE/sing-box/bin/sing-box" "$STAGE/sing-box/bin/jq"

# ---------- 7. 打包 ----------
mkdir -p "$OUT_DIR"
if [ -z "$OUT_ZIP" ]; then
  OUT_ZIP="$OUT_DIR/sing-box-module-${VER_NAME}-${VER_CODE}-${VER_HASH}-${BUILD_TYPE}-${TARGET_ABI}.zip"
fi
rm -f "$OUT_ZIP"
(cd "$STAGE" && zip -rq "$OUT_ZIP" .)

echo
info "已生成: $OUT_ZIP"
info "内置内核: $KERNEL_VER ($KERNEL_CHANNEL, $TARGET_ABI)"
info "内置 jq: $JQ_VER"
[ -f "$STAGE_BIN/atp" ] && info "内置 AndroidTProxyShell(atp): $(cat "$STAGE_BIN/atp_version" 2>/dev/null || echo unknown)"
ls -lh "$OUT_ZIP"

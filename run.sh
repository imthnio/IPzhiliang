#!/bin/sh
# ==============================================================================
# IPzhiliang 通用自举入口脚本 (POSIX sh)
# 自动识别系统 (Alpine / Debian / Ubuntu / CentOS / Rocky / Arch / OpenWrt / FreeBSD / macOS)
# 自动补齐 bash / curl / jq，再拉取并运行最新独立版 ipzhiliang.sh
# ==============================================================================

set -u

MAIN_SCRIPT_URL="https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh"
TMP_MAIN=""

cleanup() {
    if [ -n "$TMP_MAIN" ] && [ -f "$TMP_MAIN" ]; then
        rm -f "$TMP_MAIN"
    fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# 检测是否需要 sudo
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

# 查找可用的 bash（优先较新版本，同时完整兼容 macOS 自带 Bash 3.2）
find_bash() {
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
        if [ -x "$b" ]; then
            echo "$b"
            return 0
        fi
    done
    if command -v bash >/dev/null 2>&1; then
        command -v bash
        return 0
    fi
    return 1
}

install_pkg() {
    pkgs="$*"
    if [ -z "$pkgs" ]; then
        return 0
    fi
    printf "\033[36m[IPzhiliang] 检测到缺少基础依赖 (%s)，正在自动安装...\033[0m\n" "$pkgs"
    if command -v apk >/dev/null 2>&1; then
        $SUDO apk add --no-cache $pkgs ca-certificates
    elif command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq $pkgs ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y -q $pkgs ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y -q $pkgs ca-certificates
    elif command -v pacman >/dev/null 2>&1; then
        $SUDO pacman -Sy --noconfirm $pkgs ca-certificates
    elif command -v zypper >/dev/null 2>&1; then
        $SUDO zypper --non-interactive install $pkgs ca-certificates
    elif command -v opkg >/dev/null 2>&1; then
        $SUDO opkg update && $SUDO opkg install $pkgs ca-bundle
    elif command -v pkg >/dev/null 2>&1; then
        $SUDO pkg install -y $pkgs ca_root_nss
    elif command -v brew >/dev/null 2>&1; then
        brew install $pkgs
    else
        printf "\033[31m[错误] 无法识别包管理器，请手动安装: %s\033[0m\n" "$pkgs"
        exit 1
    fi
}

# 1. 自动检查并补齐 curl / bash / jq
NEED_PKGS=""
if ! command -v curl >/dev/null 2>&1; then
    NEED_PKGS="$NEED_PKGS curl"
fi
if ! find_bash >/dev/null 2>&1; then
    NEED_PKGS="$NEED_PKGS bash"
fi
if ! command -v jq >/dev/null 2>&1; then
    NEED_PKGS="$NEED_PKGS jq"
fi

if [ -n "$NEED_PKGS" ]; then
    install_pkg $NEED_PKGS
fi

BASH_BIN=$(find_bash) || {
    printf "\033[31m[错误] 未能安装或找到 Bash，请手动安装后重试。\033[0m\n"
    exit 1
}

# 2. 创建兼容 BusyBox / GNU / macOS 的安全临时文件 (0600 权限) 并拉取最新主脚本
OLD_UMASK=$(umask)
umask 077
if command -v mktemp >/dev/null 2>&1; then
    TMP_MAIN=$(mktemp "${TMPDIR:-/tmp}/ipzhiliang_main.XXXXXX" 2>/dev/null) || TMP_MAIN=""
fi
if [ -z "$TMP_MAIN" ]; then
    TMP_MAIN="${TMPDIR:-/tmp}/ipzhiliang_main.$$"
    rm -f "$TMP_MAIN" 2>/dev/null || true
    : > "$TMP_MAIN"
fi
chmod 600 "$TMP_MAIN" 2>/dev/null || true
umask "$OLD_UMASK"

TS=$(date +%s)
if command -v curl >/dev/null 2>&1; then
    curl -fsL --connect-timeout 10 --max-time 25 -H "Cache-Control: no-cache" "${MAIN_SCRIPT_URL}?t=${TS}" -o "$TMP_MAIN"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP_MAIN" "${MAIN_SCRIPT_URL}?t=${TS}"
else
    printf "\033[31m[错误] 未找到 curl 或 wget，无法下载主脚本。\033[0m\n"
    exit 1
fi

if [ ! -s "$TMP_MAIN" ] || ! grep -q "IPzhiliang" "$TMP_MAIN" 2>/dev/null; then
    printf "\033[31m[错误] 下载或校验 ipzhiliang.sh 失败，请检查网络连接。\033[0m\n"
    exit 1
fi

# 3. 运行主脚本（标记已由自举脚本拉取最新版，避免重复检查自更新；安全检测控制终端）
export IPZHILIANG_BOOTSTRAPPED=1
if (: </dev/tty) 2>/dev/null; then
    "$BASH_BIN" "$TMP_MAIN" "$@" </dev/tty
else
    "$BASH_BIN" "$TMP_MAIN" "$@"
fi

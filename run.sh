#!/bin/sh
# ==============================================================================
# IPzhiliang 通用自举入口脚本 (POSIX sh)
# 自动识别系统 (Alpine / Debian / Ubuntu / CentOS / Rocky / Arch / macOS)
# 自动补齐 bash (>=4.0) 与 curl，再拉取并运行最新 ipzhiliang.sh
# ==============================================================================

set -u

MAIN_SCRIPT_URL="https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh"
TMP_MAIN=""

cleanup() {
    if [ -n "$TMP_MAIN" ] && [ -f "$TMP_MAIN" ]; then
        rm -f "$TMP_MAIN"
    fi
}
trap cleanup EXIT INT TERM

# 检测是否需要 sudo
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
fi

# 查找可用的 bash >= 4.0
find_bash4() {
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
        if [ -x "$b" ]; then
            ver=$("$b" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 0)
            case "$ver" in
                ''|*[!0-9]*) ver=0 ;;
            esac
            if [ "$ver" -ge 4 ]; then
                echo "$b"
                return 0
            fi
        fi
    done
    if command -v bash >/dev/null 2>&1; then
        b=$(command -v bash)
        ver=$("$b" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 0)
        case "$ver" in
            ''|*[!0-9]*) ver=0 ;;
        esac
        if [ "$ver" -ge 4 ]; then
            echo "$b"
            return 0
        fi
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

# 1. 自动检查并补齐 curl 与 bash (>=4.0)
NEED_PKGS=""
if ! command -v curl >/dev/null 2>&1; then
    NEED_PKGS="$NEED_PKGS curl"
fi
if ! find_bash4 >/dev/null 2>&1; then
    NEED_PKGS="$NEED_PKGS bash"
fi

if [ -n "$NEED_PKGS" ]; then
    install_pkg $NEED_PKGS
fi

BASH4_BIN=$(find_bash4) || {
    printf "\033[31m[错误] 未能安装或找到 Bash 4.0+，请手动升级 Bash 后重试。\033[0m\n"
    exit 1
}

# 2. 创建兼容 BusyBox / GNU / macOS 的临时文件并拉取最新主脚本
if command -v mktemp >/dev/null 2>&1; then
    TMP_MAIN=$(mktemp "${TMPDIR:-/tmp}/ipzhiliang_main.XXXXXX" 2>/dev/null) || TMP_MAIN=""
fi
if [ -z "$TMP_MAIN" ]; then
    TMP_MAIN="${TMPDIR:-/tmp}/ipzhiliang_main.$$"
    : > "$TMP_MAIN"
fi

TS=$(date +%s)
if command -v curl >/dev/null 2>&1; then
    curl -fsL --connect-timeout 10 --max-time 25 -H "Cache-Control: no-cache" "${MAIN_SCRIPT_URL}?t=${TS}" -o "$TMP_MAIN"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP_MAIN" "${MAIN_SCRIPT_URL}?t=${TS}"
else
    printf "\033[31m[错误] 未找到 curl 或 wget，无法下载主脚本。\033[0m\n"
    exit 1
fi

if [ ! -s "$TMP_MAIN" ]; then
    printf "\033[31m[错误] 下载 ipzhiliang.sh 失败，请检查网络连接。\033[0m\n"
    exit 1
fi

# 3. 使用 Bash 4+ 运行主脚本（确保绑定终端输入）
if [ -r /dev/tty ]; then
    "$BASH4_BIN" "$TMP_MAIN" "$@" </dev/tty
else
    "$BASH4_BIN" "$TMP_MAIN" "$@"
fi

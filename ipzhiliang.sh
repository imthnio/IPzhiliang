#!/usr/bin/env bash
# ==============================================================================
# IPzhiliang - 独立开源 IP 质量与流媒体/AI 解锁一键检测工具
# GitHub: https://github.com/imthnio/IPzhiliang
# License: MIT (100% 独立引擎 · 零第三方中转 · 零报告上传 · 零广告统计)
# ==============================================================================

set -u

VERSION="2.3.0"
SELF_RAW_URL="https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh"
KEYS_CONFIG_FILE="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/ipzhiliang/keys.env"

# 颜色定义
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_ITALIC="\033[3m"
C_UNDERLINE="\033[4m"
C_BLACK="\033[30m"
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_PURPLE="\033[35m"
C_CYAN="\033[36m"
C_WHITE="\033[37m"

BG_GREEN="\033[42m"
BG_YELLOW="\033[43m"
BG_RED="\033[41m"
BG_BLUE="\033[44m"
BG_PURPLE="\033[45m"

UA_CHROME="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36"

# 运行配置状态
TARGET_MODE="machine"      # machine | port | iface
TARGET_PORTS=()            # 单个或多个端口/代理 URL
TARGET_IFACE=""            # 网卡名或出口 IP
PRIVACY_MODE="1"           # 1:隐私打码模式(默认,纯本地零上传) | 2:本地完整模式(-f,纯本地零上传)
IP_STACK="both"            # both | 4 | 6
LANG_CODE="cn"             # cn | en
OUTPUT_FILE=""             # 导出文件路径 (.txt / .ansi / .json)
JSON_MODE=0                # -j 纯 JSON 输出
DEP_MODE="auto"            # auto(-y) | skip(-n)
MAIL_MODE="skip_default"   # skip_default(默认防云商25端口风控断连) | enable(--mail) | skip_user(--no-mail)
SKIP_MEDIA=0               # --no-media 跳过流媒体与 AI 检测
DRY_RUN=0                  # 仅展示配置不执行
NON_INTERACTIVE=0          # CLI 直通模式

# 当前检测上下文
ACTIVE_CURL_CFG=""
ACTIVE_IFACE=""
ACTIVE_PROXY_DISPLAY=""
TMP_WORKDIR=""
TMP_CURL_CFG=""

# 内置已验证可用的 22 个权威公开 DNSBL 列表（同时支持读取同目录 dnsbl.list）
EMBEDDED_DNSBL_LIST=(
    "bl.spamcop.net"
    "b.barracudacentral.org"
    "dnsbl-1.uceprotect.net"
    "dnsbl-2.uceprotect.net"
    "dnsbl-3.uceprotect.net"
    "dnsbl.dronebl.org"
    "psbl.surriel.com"
    "all.s5h.net"
    "bl.mailspike.net"
    "z.mailspike.net"
    "rbl.interserver.net"
    "spam.dnsbl.anonmails.de"
    "dnsbl.justspam.org"
    "bl.0spam.org"
    "tor.dan.me.uk"
    "bl.nordspam.com"
    "dnsbl.spfbl.net"
    "truncate.gbudb.net"
    "bl.blocklist.de"
    "korea.services.net"
    "hostkarma.junkemailfilter.com"
    "spam.rbl.blockedservers.com"
)

cleanup() {
    local pids
    pids=$(jobs -p 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        kill $pids 2>/dev/null || true
    fi
    if [[ -n "$TMP_CURL_CFG" && -f "$TMP_CURL_CFG" ]]; then
        rm -f "$TMP_CURL_CFG"
    fi
    if [[ -n "$TMP_WORKDIR" && -d "$TMP_WORKDIR" ]]; then
        rm -rf "$TMP_WORKDIR"
    fi
}
trap cleanup EXIT
trap 'cleanup; echo -e "\n${C_YELLOW}已取消检测。${C_RESET}"; exit 130' INT TERM HUP

# ==============================================================================
# 基础工具函数（兼容 Bash 3.2+ / macOS / Alpine / Debian / CentOS / OpenWrt / FreeBSD）
# ==============================================================================

has_controlling_tty() {
    (: </dev/tty) 2>/dev/null
}

tty_read() {
    local __tty_prompt="$1"
    local __tty_var="$2"
    local __tty_silent="${3:-0}"
    local __tty_val=""
    local __tty_rc=0

    if has_controlling_tty; then
        if [[ "$__tty_silent" == "1" ]]; then
            read -r -s -p "$__tty_prompt" __tty_val </dev/tty || __tty_rc=$?
            echo "" >/dev/tty
        else
            read -r -p "$__tty_prompt" __tty_val </dev/tty || __tty_rc=$?
        fi
    else
        if [[ "$__tty_silent" == "1" ]]; then
            read -r -s -p "$__tty_prompt" __tty_val || __tty_rc=$?
            echo "" >&2
        else
            read -r -p "$__tty_prompt" __tty_val || __tty_rc=$?
        fi
    fi

    if [[ $__tty_rc -ne 0 && -z "$__tty_val" ]]; then
        echo -e "\n${C_YELLOW}输入流已结束 (EOF)，已安全退出。${C_RESET}" >&2
        exit 0
    fi

    printf -v "$__tty_var" '%s' "$__tty_val"
}

make_temp_file() {
    local prefix="${1:-ipzhiliang}"
    local f=""
    local old_umask
    old_umask=$(umask)
    umask 077
    if command -v mktemp >/dev/null 2>&1; then
        f=$(mktemp "${TMPDIR:-/tmp}/${prefix}.XXXXXX" 2>/dev/null) || f=""
    fi
    if [[ -z "$f" ]]; then
        f="${TMPDIR:-/tmp}/${prefix}.$$.${RANDOM:-0}"
        rm -f "$f" 2>/dev/null || true
        : > "$f"
    fi
    chmod 600 "$f" 2>/dev/null || true
    umask "$old_umask"
    echo "$f"
}

make_temp_dir() {
    local prefix="${1:-ipzhiliang_work}"
    local d=""
    local old_umask
    old_umask=$(umask)
    umask 077
    if command -v mktemp >/dev/null 2>&1; then
        d=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX" 2>/dev/null) || d=""
    fi
    if [[ -z "$d" ]]; then
        d="${TMPDIR:-/tmp}/${prefix}.$$.${RANDOM:-0}"
        mkdir -p "$d"
    fi
    chmod 700 "$d" 2>/dev/null || true
    umask "$old_umask"
    echo "$d"
}

# 根据容器 cgroup pids.max 与内存限额自动计算安全并发度（兼容低配 LXD/LXC/NAT 小鸡，杜绝 fork 失败与 OOM 断连）
detect_max_jobs() {
    local pid_cap=6 mem_cap=6
    local pmax="" pcur=0 avail_pids=0
    if [[ -r /sys/fs/cgroup/pids.max ]]; then
        pmax=$(cat /sys/fs/cgroup/pids.max 2>/dev/null || true)
        pcur=$(cat /sys/fs/cgroup/pids.current 2>/dev/null || echo 0)
    elif [[ -r /sys/fs/cgroup/pids/pids.max ]]; then
        pmax=$(cat /sys/fs/cgroup/pids/pids.max 2>/dev/null || true)
        pcur=$(cat /sys/fs/cgroup/pids/pids.current 2>/dev/null || echo 0)
    fi

    if [[ "$pmax" =~ ^[0-9]+$ && "$pcur" =~ ^[0-9]+$ ]]; then
        avail_pids=$(( pmax - pcur ))
        if (( avail_pids <= 18 )); then
            pid_cap=1
        elif (( avail_pids <= 40 )); then
            pid_cap=2
        elif (( avail_pids <= 90 )); then
            pid_cap=3
        elif (( avail_pids <= 160 )); then
            pid_cap=4
        else
            pid_cap=6
        fi
    else
        pid_cap=5
    fi

    local mmax="" mcur=0 limit_mb=0 avail_mb=0
    if [[ -r /sys/fs/cgroup/memory.max ]]; then
        mmax=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
        mcur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)
    elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
        mmax=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)
        mcur=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0)
    fi

    if [[ "$mmax" =~ ^[0-9]+$ && ${#mmax} -le 13 ]]; then
        limit_mb=$(( mmax / 1048576 ))
        [[ "$mcur" =~ ^[0-9]+$ ]] && avail_mb=$(( (mmax - mcur) / 1048576 )) || avail_mb=$limit_mb
        if (( limit_mb > 0 )); then
            if (( avail_mb <= 64 || limit_mb <= 128 )); then
                mem_cap=1
            elif (( avail_mb <= 160 || limit_mb <= 280 )); then
                mem_cap=2
            elif (( avail_mb <= 320 || limit_mb <= 512 )); then
                mem_cap=3
            elif (( avail_mb <= 640 )); then
                mem_cap=4
            fi
        fi
    elif [[ -r /proc/meminfo ]]; then
        local kb
        kb=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
        [[ -z "$kb" ]] && kb=$(awk '/^MemFree:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
        if [[ "$kb" =~ ^[0-9]+$ ]]; then
            avail_mb=$(( kb / 1024 ))
            if (( avail_mb <= 64 )); then
                mem_cap=1
            elif (( avail_mb <= 160 )); then
                mem_cap=2
            elif (( avail_mb <= 320 )); then
                mem_cap=3
            elif (( avail_mb <= 640 )); then
                mem_cap=4
            fi
        fi
    fi

    if (( pid_cap < mem_cap )); then
        echo "$pid_cap"
    else
        echo "$mem_cap"
    fi
}

# 跨平台纯 Bash 单 PID 超时看门狗（绝不调用 BusyBox timeout，杜绝进程组信号误杀 SSH 会话与孤儿 sleep）
run_with_timeout() {
    local secs="$1"
    shift
    exec 3<&0
    "$@" <&3 &
    local cmd_pid=$!
    exec 3<&-
    (
        sleep "$secs" &
        local spid=$!
        trap 'kill "$spid" 2>/dev/null || true; exit 0' TERM INT
        wait "$spid" 2>/dev/null || true
        kill -TERM "$cmd_pid" 2>/dev/null || true
        sleep 1 &
        spid=$!
        wait "$spid" 2>/dev/null || true
        kill -KILL "$cmd_pid" 2>/dev/null || true
    ) </dev/null >/dev/null 2>&1 &
    local wd_pid=$!
    local rc=0
    wait "$cmd_pid" 2>/dev/null || rc=$?
    kill -TERM "$wd_pid" 2>/dev/null || true
    wait "$wd_pid" 2>/dev/null || true
    return "$rc"
}

curl_supports_parallel() {
    (curl --help all 2>/dev/null || curl --help 2>/dev/null) | grep -q -- '--parallel'
}

strip_ansi() {
    local esc
    esc=$(printf '\033')
    sed "s/${esc}\[[0-9;]*[a-zA-Z]//g"
}

is_ephemeral_script_path() {
    local p="${1:-}"
    if [[ -z "$p" || ! -f "$p" || "$p" == /dev/fd/* || "$p" == /proc/self/fd/* || "$p" == */ipzhiliang_main.* || "${IPZHILIANG_BOOTSTRAPPED:-0}" == "1" ]]; then
        return 0
    fi
    return 1
}

self_update() {
    local target_path="${BASH_SOURCE[0]:-}"
    if is_ephemeral_script_path "$target_path"; then
        echo -e "${C_GREEN}[提示] 你正在通过远程一键命令运行，每次执行均自动拉取最新独立版脚本。${C_RESET}"
        exit 0
    fi

    echo -e "${C_DIM}正在从 GitHub 拉取最新 ipzhiliang.sh ...${C_RESET}"
    local tmp_new
    tmp_new=$(make_temp_file "ipzhiliang_update")
    if curl -fsL --connect-timeout 8 --max-time 20 -H "Cache-Control: no-cache" "${SELF_RAW_URL}?t=$(date +%s)" -o "$tmp_new" 2>/dev/null && grep -q "IPzhiliang" "$tmp_new"; then
        local new_ver
        new_ver=$(grep -m1 '^VERSION=' "$tmp_new" | cut -d'"' -f2)
        chmod +x "$tmp_new" 2>/dev/null || true
        if mv -f "$tmp_new" "$target_path" 2>/dev/null; then
            echo -e "${C_GREEN}[成功] 已更新至最新版本 v${new_ver:-unknown} (${target_path})${C_RESET}"
            exit 0
        else
            rm -f "$tmp_new"
            echo -e "${C_RED}[错误] 无法写入 ${target_path}，请检查文件权限（如使用 sudo）。${C_RESET}"
            exit 1
        fi
    else
        rm -f "$tmp_new"
        echo -e "${C_RED}[错误] 自更新失败，请检查网络连接后重试。${C_RESET}"
        exit 1
    fi
}

check_self_update() {
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    [[ "${IPZHILIANG_SKIP_UPDATE:-0}" == "1" ]] && return 0

    local target_path="${BASH_SOURCE[0]:-}"
    if is_ephemeral_script_path "$target_path"; then
        return 0
    fi

    local remote_ver
    remote_ver=$(curl -fsL --connect-timeout 2 --max-time 3 -H "Cache-Control: no-cache" "${SELF_RAW_URL}?t=$(date +%s)" 2>/dev/null | grep -m1 '^VERSION=' | cut -d'"' -f2)
    if [[ -n "$remote_ver" && "$remote_ver" != "$VERSION" ]]; then
        echo -e "${C_CYAN}[自动更新] 发现新版本 v${remote_ver} (当前 v${VERSION})，正在自动更新...${C_RESET}"
        local tmp_new
        tmp_new=$(make_temp_file "ipzhiliang_update")
        if curl -fsL --connect-timeout 8 --max-time 20 -H "Cache-Control: no-cache" "${SELF_RAW_URL}?t=$(date +%s)" -o "$tmp_new" 2>/dev/null && grep -q "IPzhiliang" "$tmp_new"; then
            local downloaded_ver
            downloaded_ver=$(grep -m1 '^VERSION=' "$tmp_new" | cut -d'"' -f2)
            chmod +x "$tmp_new" 2>/dev/null || true
            if [[ -n "$downloaded_ver" && "$downloaded_ver" != "$VERSION" ]] && mv -f "$tmp_new" "$target_path" 2>/dev/null; then
                echo -e "${C_GREEN}[自动更新] 已更新至 v${downloaded_ver}，正在无缝启动新版...${C_RESET}"
                echo ""
                export IPZHILIANG_SKIP_UPDATE=1
                exec "${BASH:-bash}" "$target_path" "$@"
            else
                rm -f "$tmp_new"
                echo -e "${C_YELLOW}[提示] 自动更新写入失败或版本未变更，继续使用当前版本运行。${C_RESET}"
            fi
        else
            rm -f "$tmp_new"
            echo -e "${C_YELLOW}[提示] 自动更新拉取失败，继续使用当前版本运行。${C_RESET}"
        fi
    fi
}

detect_host_env() {
    local os_name="Unknown"
    local virt_type="物理机(母鸡)"

    if [[ -r /etc/os-release ]]; then
        os_name=$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        os_name="macOS $(sw_vers -productVersion 2>/dev/null || true)"
    else
        os_name="$(uname -s) $(uname -r)"
    fi

    local pid1_env=""
    if [[ -r /proc/1/environ ]]; then
        pid1_env=$(tr '\0' '\n' < /proc/1/environ 2>/dev/null || true)
    fi

    if [[ -f /.dockerenv ]] || grep -qaE 'docker|containerd' /proc/1/cgroup 2>/dev/null || grep -qiE '^container=(docker|podman)' <<< "$pid1_env"; then
        virt_type="Docker容器(小鸡)"
    elif [[ -f /proc/user_beancounters ]] || [[ -d /proc/vz ]]; then
        virt_type="OpenVZ(小鸡)"
    elif grep -qaE 'lxc|kubepods' /proc/1/cgroup 2>/dev/null || [[ "${container:-}" == "lxc" ]] || grep -qi '^container=lxc' <<< "$pid1_env"; then
        virt_type="LXC容器(小鸡)"
    else
        if command -v systemd-detect-virt >/dev/null 2>&1; then
            local v
            v=$(systemd-detect-virt 2>/dev/null || true)
            if [[ -n "$v" && "$v" != "none" ]]; then
                virt_type="${v}(小鸡)"
            fi
        fi
        if [[ "$virt_type" == "物理机(母鸡)" && -r /sys/class/dmi/id/product_name ]]; then
            local prod
            prod=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
            case "$prod" in
                *KVM*|*QEMU*) virt_type="KVM(小鸡)" ;;
                *VMware*) virt_type="VMware(小鸡)" ;;
                *VirtualBox*) virt_type="VirtualBox(小鸡)" ;;
                *Xen*) virt_type="Xen(小鸡)" ;;
                *Hyper-V*|*"Virtual Machine"*) virt_type="Hyper-V(小鸡)" ;;
            esac
        elif [[ "$(uname -s)" == "Darwin" ]]; then
            virt_type="macOS本机"
        fi
    fi

    echo "${os_name} · ${virt_type}"
}

install_missing_dep() {
    local pkg="$1"
    local sudo_cmd=""
    if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
        sudo_cmd="sudo"
    fi
    echo -e "${C_CYAN}[依赖安装] 正在自动安装 ${pkg}...${C_RESET}" >&2
    if command -v apk >/dev/null 2>&1; then
        $sudo_cmd apk add --no-cache "$pkg" >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        $sudo_cmd apt-get update -qq >/dev/null 2>&1 && $sudo_cmd apt-get install -y -qq "$pkg" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        $sudo_cmd dnf install -y -q "$pkg" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        $sudo_cmd yum install -y -q "$pkg" >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        $sudo_cmd pacman -Sy --noconfirm "$pkg" >/dev/null 2>&1
    elif command -v zypper >/dev/null 2>&1; then
        $sudo_cmd zypper --non-interactive install "$pkg" >/dev/null 2>&1
    elif command -v opkg >/dev/null 2>&1; then
        $sudo_cmd opkg update >/dev/null 2>&1 && $sudo_cmd opkg install "$pkg" >/dev/null 2>&1
    elif command -v pkg >/dev/null 2>&1; then
        $sudo_cmd pkg install -y "$pkg" >/dev/null 2>&1
    elif command -v brew >/dev/null 2>&1; then
        brew install "$pkg" >/dev/null 2>&1
    else
        return 1
    fi
}

check_env() {
    if ! command -v curl >/dev/null 2>&1; then
        if [[ "$DEP_MODE" == "auto" && "$DRY_RUN" -eq 0 ]]; then
            install_missing_dep curl || true
        fi
        if ! command -v curl >/dev/null 2>&1; then
            echo -e "${C_RED}[错误] 未检测到 curl，请先安装 curl 后重试。${C_RESET}"
            exit 1
        fi
    fi

    if ! command -v jq >/dev/null 2>&1; then
        if [[ "$DEP_MODE" == "auto" && "$DRY_RUN" -eq 0 ]]; then
            install_missing_dep jq || true
        fi
        if ! command -v jq >/dev/null 2>&1 && [[ "$DRY_RUN" -eq 0 ]]; then
            echo -e "${C_RED}[错误] 未检测到 jq（JSON 解析依赖），请安装 jq 后重试：${C_RESET}"
            echo -e "${C_DIM}  Debian/Ubuntu: apt install -y jq  |  Alpine: apk add jq  |  macOS: brew install jq${C_RESET}"
            exit 1
        fi
    fi
}

print_banner() {
    local host_env
    host_env=$(detect_host_env)
    echo -e "${C_CYAN}${C_BOLD}"
    echo "================================================================"
    echo "          IPzhiliang · 独立隐私优先 IP 质量一键检测工具"
    echo "================================================================"
    echo -e "${C_RESET}${C_DIM} 版本: v${VERSION}  |  引擎: 独立自研并行引擎 (零中转 / 零上传 / 零广告)${C_RESET}"
    echo -e "${C_DIM} 环境: ${host_env}${C_RESET}"
    echo -e "${C_DIM} 仓库: https://github.com/imthnio/IPzhiliang${C_RESET}"
    echo ""
}

print_usage() {
    cat <<EOF
IPzhiliang v${VERSION} - 独立开源、隐私优先的 IP 质量与流媒体/AI 解锁检测工具

用法:
  交互式运行 (推荐):
    bash <(curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh)

  命令行直通运行:
    bash ipzhiliang.sh [选项]

选项:
  --port <目标>      检测指定端口/代理出口 (支持 21233 / 127.0.0.1:21233 / socks5://... / 多端口逗号分隔)
  --iface <网卡/IP>  检测指定出口网卡或出口 IP (如 eth0 / warp / 1.2.3.4)
  --privacy          隐私打码模式：全程隐藏/打码公网 IP，纯本地零上传 [默认]
  --full, -f         本地完整模式：仅在本地展示完整 IP，同样零上传
  -4                 仅检测 IPv4
  -6                 仅检测 IPv6
  -l <语言>          报告语言: cn (中文) | en (English) [默认 cn]
  -E                 英文报告 (等同于 -l en)
  -o <路径>          将报告保存到本地文件 (.txt / .ansi / .json，自动设为 0600 权限)
  -j                 在终端输出结构化 JSON 结果
  --no-media         跳过 AI 与流媒体解锁检测
  --mail             开启 25 端口邮局出站探测 (默认跳过，防止触发云商 25 端口风控断连)
  --no-mail          显式跳过 25 端口邮局连通性检测
  -y                 自动安装缺失依赖 (curl / jq) [默认]
  -n                 跳过依赖自动安装
  --update           将本地 ipzhiliang.sh 更新到 GitHub 最新版本
  --keys             交互式查看/配置免费扩展数据库 API Key (保存至 ~/.config/ipzhiliang/keys.env, 0600 权限)
  --dry-run          仅预览检测配置，不发起实际网络检测
  -h, --help         显示本帮助信息

免 Key 内置直连数据库 (9 大零中转权威源，开箱即用):
  IPinfo · ipregistry · IP2Location(PX12完整版) · Scamalytics · ProxyCheck · IPQuery · IP-API · DB-IP · StopForumSpam (+ ip.guide)

可选自有免费 API Key 扩展（环境变量或 --keys 本地配置，直连官方零中转）:
  IPAPI_IS_API_KEY     启用 ipapi.is 完整版 (使用/公司类型 + abuser_score + 风险因子，免费 1,000 次/天)
  ABUSEIPDB_API_KEY    启用 AbuseIPDB 官方 API (使用类型 + 置信度风险分 + 滥用/Tor，免费 1,000 次/天)
  IPDATA_API_KEY       启用 ipdata 官方威胁库 (地区/代理/Tor/服务器/滥用，免费 1,500 次/天)
  IPQS_API_KEY         启用 IPQualityScore 官方库 (欺诈分 + 代理/Tor/VPN/滥用/机器人，免费 5,000 次/月)
  IP2LOCATION_API_KEY  使用自有 IP2Location.io Key (可选，免 Key 已内置完整 PX12 演示库)
  IPREGISTRY_API_KEY   使用自有 ipregistry Key (可选，免 Key 已直连可用)
  DBIP_API_KEY         使用自有 DB-IP Key (可选，免 Key 已直连可用)
  MAXMIND_ACCOUNT_ID / MAXMIND_LICENSE_KEY  启用 MaxMind GeoLite2/GeoIP2 官方基础地理库 (可选)
EOF
}

# ==============================================================================
# 可选自有 API Key 安全加载与交互配置 (仅读取白名单变量，0600 权限，绝不 source 任意代码)
# ==============================================================================

mask_api_key() {
    local k="${1:-}"
    local len=${#k}
    if (( len == 0 )); then
        echo "未配置"
    elif (( len <= 8 )); then
        echo "***"
    else
        echo "${k:0:4}***${k:len-4:4}"
    fi
}

load_saved_keys() {
    [[ -r "$KEYS_CONFIG_FILE" ]] || return 0
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" != *=* ]] && continue
        key="${line%%=*}"
        val="${line#*=}"
        val="${val#\"}"
        val="${val%\"}"
        val="${val#\'}"
        val="${val%\'}"
        case "$key" in
            IPAPI_IS_API_KEY|ABUSEIPDB_API_KEY|IPDATA_API_KEY|IPQS_API_KEY|IP2LOCATION_API_KEY|IPREGISTRY_API_KEY|DBIP_API_KEY|MAXMIND_ACCOUNT_ID|MAXMIND_LICENSE_KEY)
                if [[ -z "${!key:-}" && -n "$val" ]]; then
                    printf -v "$key" '%s' "$val"
                    export "$key"
                fi
                ;;
        esac
    done < "$KEYS_CONFIG_FILE"
}

save_keys_config() {
    local cfg_dir
    cfg_dir=$(dirname "$KEYS_CONFIG_FILE")
    local old_umask
    old_umask=$(umask)
    umask 077
    mkdir -p "$cfg_dir" 2>/dev/null || {
        umask "$old_umask"
        echo -e "${C_RED}[错误] 无法创建配置目录: ${cfg_dir}${C_RESET}" >&2
        return 1
    }
    chmod 700 "$cfg_dir" 2>/dev/null || true
    {
        echo "# IPzhiliang optional API keys (chmod 600, direct official API only)"
        local k v
        for k in IPAPI_IS_API_KEY ABUSEIPDB_API_KEY IPDATA_API_KEY IPQS_API_KEY IP2LOCATION_API_KEY IPREGISTRY_API_KEY DBIP_API_KEY MAXMIND_ACCOUNT_ID MAXMIND_LICENSE_KEY; do
            v="${!k:-}"
            [[ -n "$v" ]] && printf '%s=%s\n' "$k" "$v"
        done
    } > "$KEYS_CONFIG_FILE"
    chmod 600 "$KEYS_CONFIG_FILE" 2>/dev/null || true
    umask "$old_umask"
    echo -e "${C_GREEN}[已保存] API Key 已加密权限写入 ${KEYS_CONFIG_FILE} (0600)${C_RESET}"
}

has_any_byok_keys() {
    [[ -n "${IPAPI_IS_API_KEY:-}" || -n "${ABUSEIPDB_API_KEY:-}" || -n "${IPDATA_API_KEY:-}" || -n "${IPQS_API_KEY:-}" || -n "${IP2LOCATION_API_KEY:-}" || -n "${IPREGISTRY_API_KEY:-}" || -n "${DBIP_API_KEY:-}" || ( -n "${MAXMIND_ACCOUNT_ID:-}" && -n "${MAXMIND_LICENSE_KEY:-}" ) ]]
}

configure_api_keys_interactive() {
    load_saved_keys
    echo ""
    echo -e "${C_BOLD}${C_PURPLE}=== 免费扩展数据库 API Key 管理 (纯本地 0600 保存 · 直连官方零中转) ===${C_RESET}"
    echo -e "${C_DIM}内置 9 大免 Key 数据库已默认全开：IPinfo / ipregistry / IP2Location(PX12) / Scamalytics / ProxyCheck / IPQuery / IP-API / DB-IP / StopForumSpam${C_RESET}"
    echo -e "${C_DIM}以下扩展库官方要求自有免费 Key（输入新 Key 更新，输入 clear 清空，直接回车跳过）：${C_RESET}"
    echo ""

    while true; do
        echo -e "  ${C_GREEN}1)${C_RESET} ipapi.is         (免费 1,000 次/天, https://ipapi.is/)        当前: ${C_CYAN}$(mask_api_key "${IPAPI_IS_API_KEY:-}")${C_RESET}"
        echo -e "  ${C_GREEN}2)${C_RESET} AbuseIPDB        (免费 1,000 次/天, https://www.abuseipdb.com/) 当前: ${C_CYAN}$(mask_api_key "${ABUSEIPDB_API_KEY:-}")${C_RESET}"
        echo -e "  ${C_GREEN}3)${C_RESET} ipdata           (免费 1,500 次/天, https://ipdata.co/)       当前: ${C_CYAN}$(mask_api_key "${IPDATA_API_KEY:-}")${C_RESET}"
        echo -e "  ${C_GREEN}4)${C_RESET} IPQS             (免费 5,000 次/月, https://www.ipqualityscore.com/) 当前: ${C_CYAN}$(mask_api_key "${IPQS_API_KEY:-}")${C_RESET}"
        echo -e "  ${C_GREEN}5)${C_RESET} MaxMind GeoLite2 (免费账号+Key, https://www.maxmind.com/)     当前: ${C_CYAN}$(mask_api_key "${MAXMIND_LICENSE_KEY:-}")${C_RESET}"
        echo -e "  ${C_GREEN}6)${C_RESET} IP2Location.io   (可选加速Key, 免Key已可用)                   当前: ${C_CYAN}$(mask_api_key "${IP2LOCATION_API_KEY:-}")${C_RESET}"
        echo -e "  ${C_GREEN}7)${C_RESET} ipregistry       (可选自有Key, 免Key已可用)                   当前: ${C_CYAN}$(mask_api_key "${IPREGISTRY_API_KEY:-}")${C_RESET}"
        echo -e "  ${C_GREEN}8)${C_RESET} DB-IP            (可选自有Key, 免Key已可用)                   当前: ${C_CYAN}$(mask_api_key "${DBIP_API_KEY:-}")${C_RESET}"
        echo -e "  ${C_YELLOW}0)${C_RESET} 保存并返回"
        echo ""

        local sel="" val=""
        tty_read "请选择要配置的数据库编号 [0-8] (默认 0): " sel
        sel="${sel:-0}"
        case "$sel" in
            0|q|Q)
                save_keys_config
                echo ""
                return 0
                ;;
            1)
                tty_read "请输入 IPAPI_IS_API_KEY (输入 clear 清空, 回车取消): " val 1
                [[ "$val" == "clear" ]] && IPAPI_IS_API_KEY="" || [[ -n "$val" ]] && IPAPI_IS_API_KEY="$val"
                export IPAPI_IS_API_KEY
                ;;
            2)
                tty_read "请输入 ABUSEIPDB_API_KEY (输入 clear 清空, 回车取消): " val 1
                [[ "$val" == "clear" ]] && ABUSEIPDB_API_KEY="" || [[ -n "$val" ]] && ABUSEIPDB_API_KEY="$val"
                export ABUSEIPDB_API_KEY
                ;;
            3)
                tty_read "请输入 IPDATA_API_KEY (输入 clear 清空, 回车取消): " val 1
                [[ "$val" == "clear" ]] && IPDATA_API_KEY="" || [[ -n "$val" ]] && IPDATA_API_KEY="$val"
                export IPDATA_API_KEY
                ;;
            4)
                tty_read "请输入 IPQS_API_KEY (输入 clear 清空, 回车取消): " val 1
                [[ "$val" == "clear" ]] && IPQS_API_KEY="" || [[ -n "$val" ]] && IPQS_API_KEY="$val"
                export IPQS_API_KEY
                ;;
            5)
                local mm_id="" mm_key=""
                tty_read "请输入 MAXMIND_ACCOUNT_ID (输入 clear 清空, 回车取消): " mm_id
                if [[ "$mm_id" == "clear" ]]; then
                    MAXMIND_ACCOUNT_ID=""
                    MAXMIND_LICENSE_KEY=""
                elif [[ -n "$mm_id" ]]; then
                    tty_read "请输入 MAXMIND_LICENSE_KEY (输入不回显): " mm_key 1
                    if [[ -n "$mm_key" ]]; then
                        MAXMIND_ACCOUNT_ID="$mm_id"
                        MAXMIND_LICENSE_KEY="$mm_key"
                    fi
                fi
                export MAXMIND_ACCOUNT_ID MAXMIND_LICENSE_KEY
                ;;
            6)
                tty_read "请输入 IP2LOCATION_API_KEY (输入 clear 清空, 回车取消): " val 1
                [[ "$val" == "clear" ]] && IP2LOCATION_API_KEY="" || [[ -n "$val" ]] && IP2LOCATION_API_KEY="$val"
                export IP2LOCATION_API_KEY
                ;;
            7)
                tty_read "请输入 IPREGISTRY_API_KEY (输入 clear 清空, 回车取消): " val 1
                [[ "$val" == "clear" ]] && IPREGISTRY_API_KEY="" || [[ -n "$val" ]] && IPREGISTRY_API_KEY="$val"
                export IPREGISTRY_API_KEY
                ;;
            8)
                tty_read "请输入 DBIP_API_KEY (输入 clear 清空, 回车取消): " val 1
                [[ "$val" == "clear" ]] && DBIP_API_KEY="" || [[ -n "$val" ]] && DBIP_API_KEY="$val"
                export DBIP_API_KEY
                ;;
            *)
                echo -e "${C_YELLOW}无效编号，请输入 0-8。${C_RESET}"
                ;;
        esac
        echo ""
    done
}

# ==============================================================================
# IP 校验、URL 编码与全链路隐私脱敏
# ==============================================================================

is_ipv4_literal() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a octets=($ip)
        local o
        for o in "${octets[@]}"; do
            if (( 10#$o < 0 || 10#$o > 255 )); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

is_ipv6_literal() {
    local ip="${1%%/*}"
    ip="${ip%%%*}"
    [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:.]+$ ]]
}

is_valid_ip_literal() {
    is_ipv4_literal "$1" || is_ipv6_literal "$1"
}

is_loopback_host() {
    local h="${1#[}"
    h="${h%]}"
    [[ "$h" == "127."* || "$h" == "localhost" || "$h" == "::1" || "$h" == "0.0.0.0" || "$h" == "::" || "$h" == "*" ]]
}

urlencode_cred() {
    local LC_ALL=C
    local str="$1"
    local i c
    local out=""
    for (( i=0; i<${#str}; i++ )); do
        c="${str:i:1}"
        if [[ "$c" == "%" && "${str:i+1:2}" =~ ^[0-9a-fA-F]{2}$ ]]; then
            out+="${str:i:3}"
            i=$((i + 2))
            continue
        fi
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

normalize_proxy_auth() {
    local url="$1"
    if [[ "$url" != *"@"* ]]; then
        printf '%s' "$url"
        return
    fi

    local proto_prefix=""
    local rest="$url"
    if [[ "$url" == *"://"* ]]; then
        proto_prefix="${url%%://*}://"
        rest="${url#*://}"
    fi

    local creds="${rest%@*}"
    local hostpart="${rest##*@}"

    if [[ "$creds" == *":"* ]]; then
        local user="${creds%%:*}"
        local pass="${creds#*:}"
        printf '%s%s:%s@%s' "$proto_prefix" "$(urlencode_cred "$user")" "$(urlencode_cred "$pass")" "$hostpart"
    else
        printf '%s%s@%s' "$proto_prefix" "$(urlencode_cred "$creds")" "$hostpart"
    fi
}

# 保留首段与末段、中间段打码：既严格保护公网 IP，又能区分同 C 段/同前缀多出口 IP
mask_ip() {
    local raw="$1"
    local ip="${raw%%/*}"
    local suffix=""
    [[ "$raw" == */* ]] && suffix="/${raw#*/}"

    if [[ "$ip" == *":"* ]]; then
        local masked6
        masked6=$(echo "$ip" | awk -F: '{
            first = ($1 != "" ? $1 : "0")
            second = ($2 != "" ? $2 : "0")
            last = ($NF != "" ? $NF : "0")
            if (NF <= 3) print first":*:"last
            else print first":"second":*:*:"last
        }')
        echo "${masked6}${suffix}"
    elif [[ "$ip" == *"."* ]]; then
        local masked4
        masked4=$(echo "$ip" | awk -F. '{
            if (NF == 4) print $1".*.*."$4
            else print $1".*.*.*"
        }')
        echo "${masked4}${suffix}"
    else
        echo "$raw"
    fi
}

format_ip_display() {
    local ip="$1"
    if [[ "$PRIVACY_MODE" == "2" ]]; then
        echo "$ip"
    else
        mask_ip "$ip"
    fi
}

mask_rdns_for_privacy() {
    local host="$1"
    local ip="$2"
    [[ -z "$host" ]] && return
    if [[ "$PRIVACY_MODE" == "2" ]]; then
        echo "$host"
        return
    fi
    if is_ipv4_literal "$ip"; then
        local IFS='.'
        local -a o=($ip)
        local p1="${o[0]}" p2="${o[1]}" p3="${o[2]}" p4="${o[3]}"
        # 遮蔽 PTR 中嵌入的正序/倒序 IPv4 中间两段（如 1-2-3-4.isp.com / 4.3.2.1.isp.com）
        host=$(printf '%s' "$host" | sed -E \
            -e "s/(^|[^0-9])${p1}([.-])${p2}([.-])${p3}([.-])${p4}([^0-9]|$)/\1${p1}\2*\3*\4${p4}\5/g" \
            -e "s/(^|[^0-9])${p4}([.-])${p3}([.-])${p2}([.-])${p1}([^0-9]|$)/\1${p4}\2*\3*\4${p1}\5/g")
    fi
    echo "$host"
}

mask_proxy_url() {
    local url="$1"
    local mask_remote_host="${2:-1}"
    local proto_prefix=""
    local rest="$url"

    if [[ "$url" == *"://"* ]]; then
        proto_prefix="${url%%://*}://"
        rest="${url#*://}"
    fi

    local auth_display=""
    local hostpart="$rest"
    if [[ "$rest" == *"@"* ]]; then
        local creds="${rest%@*}"
        hostpart="${rest##*@}"
        if [[ "$creds" == *":"* ]]; then
            local user="${creds%%:*}"
            auth_display="${user}:***"
        else
            auth_display="***"
        fi
    fi

    if [[ "$mask_remote_host" == "1" && "$PRIVACY_MODE" == "1" ]]; then
        local host_only="" port_part=""
        if [[ "$hostpart" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
            host_only="${BASH_REMATCH[1]}"
            port_part=":${BASH_REMATCH[2]}"
            if ! is_loopback_host "$host_only" && is_valid_ip_literal "$host_only"; then
                hostpart="[$(mask_ip "$host_only")]${port_part}"
            fi
        elif [[ "$hostpart" =~ ^([^:]+):([0-9]+)$ ]]; then
            host_only="${BASH_REMATCH[1]}"
            port_part=":${BASH_REMATCH[2]}"
            if ! is_loopback_host "$host_only" && is_valid_ip_literal "$host_only"; then
                hostpart="$(mask_ip "$host_only")${port_part}"
            fi
        elif ! is_loopback_host "$hostpart" && is_valid_ip_literal "$hostpart"; then
            hostpart="$(mask_ip "$hostpart")"
        fi
    fi

    if [[ -n "$auth_display" ]]; then
        echo "${proto_prefix}${auth_display}@${hostpart}"
    else
        echo "${proto_prefix}${hostpart}"
    fi
}

format_iface_display() {
    local val="$1"
    if [[ "$PRIVACY_MODE" == "1" ]] && is_valid_ip_literal "$val"; then
        mask_ip "$val"
    else
        echo "$val"
    fi
}

mask_listen_addr() {
    awk '{
        addr = $1
        proc = (NF > 1 ? " " $2 : "")
        if (match(addr, /^\[[^\]]+\]:[0-9]+$/)) {
            sep = index(addr, "]:")
            host = substr(addr, 2, sep - 2)
            port = substr(addr, sep + 2)
            if (host != "::" && host != "::1" && host !~ /^fe80:/ && index(host, ":") > 0) {
                n = split(host, a, ":")
                host = (a[1] ? a[1] : "0") ":*:*:" (a[n] ? a[n] : "0")
            }
            print "[" host "]:" port proc
        } else if (match(addr, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$/)) {
            sep = index(addr, ":")
            host = substr(addr, 1, sep - 1)
            port = substr(addr, sep + 1)
            if (host !~ /^127\./ && host != "0.0.0.0") {
                split(host, a, ".")
                host = a[1] ".*.*." a[4]
            }
            print host ":" port proc
        } else {
            print $0
        }
    }'
}

# ==============================================================================
# 统一隔离 HTTP 客户端（确保所有网络请求严格走选定代理/网卡且零 ps aux 密码泄露）
# ==============================================================================

curl_exec() {
    local -a opts=()
    if [[ -n "$ACTIVE_CURL_CFG" && -f "$ACTIVE_CURL_CFG" ]]; then
        opts+=("-K" "$ACTIVE_CURL_CFG")
    elif [[ -n "$ACTIVE_IFACE" ]]; then
        opts+=("--interface" "$ACTIVE_IFACE")
    fi
    curl ${opts[@]+"${opts[@]}"} "$@"
}

# 带指定 IP 栈的 curl（代理模式下不强制本地 socket 栈，以免干扰 127.0.0.1 代理连接）
curl_exec_stack() {
    local stack="$1"
    shift
    if [[ -n "$ACTIVE_CURL_CFG" && -f "$ACTIVE_CURL_CFG" ]]; then
        curl -K "$ACTIVE_CURL_CFG" "$@"
    elif [[ -n "$ACTIVE_IFACE" ]]; then
        curl --interface "$ACTIVE_IFACE" "-${stack}" "$@"
    else
        curl "-${stack}" "$@"
    fi
}

# 获取出口 IPv4（使用纯 IPv4 域名，确保 socks5h 代理下也能精准获取代理 IPv4）
fetch_egress_ipv4() {
    local ep ip
    local endpoints=("https://api.ipify.org" "https://ipv4.icanhazip.com" "https://v4.ident.me" "https://4.ipw.cn")
    for ep in "${endpoints[@]}"; do
        ip=$(curl_exec_stack 4 -fsL --connect-timeout 3 --max-time 5 "$ep" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$ip" ]] && is_ipv4_literal "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 获取出口 IPv6（使用纯 IPv6 域名，确保 socks5h 代理下也能精准获取代理 IPv6）
fetch_egress_ipv6() {
    local ep ip
    local endpoints=("https://api6.ipify.org" "https://ipv6.icanhazip.com" "https://v6.ident.me" "https://6.ipw.cn")
    for ep in "${endpoints[@]}"; do
        ip=$(curl_exec_stack 6 -fsL --connect-timeout 3 --max-time 5 "$ep" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$ip" ]] && is_ipv6_literal "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# ==============================================================================
# 端口探测与交互配置
# ==============================================================================

check_local_port_listen() {
    local port="$1"
    local out=""
    if command -v ss >/dev/null 2>&1; then
        out=$(ss -tuln 2>/dev/null | grep -E ":${port}([[:space:]]|$)" | head -n 3 || true)
    fi
    if [[ -z "$out" ]] && command -v netstat >/dev/null 2>&1; then
        out=$(netstat -tuln 2>/dev/null | grep -E "[:.]${port}([[:space:]]|$)" | head -n 3 || true)
    fi
    if [[ -z "$out" ]] && command -v lsof >/dev/null 2>&1; then
        out=$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | tail -n +2 | head -n 3 || true)
    fi
    [[ -n "$out" ]] && echo "$out"
}

show_listening_ports_hint() {
    local lines=""
    if command -v ss >/dev/null 2>&1; then
        lines=$(ss -tulnp 2>/dev/null | awk 'NR>1 && $1 ~ /tcp/ {print $5, $7}' | awk '!seen[$0]++' | head -n 12 || true)
    fi
    if [[ -z "$lines" ]] && command -v netstat >/dev/null 2>&1; then
        lines=$(netstat -tuln 2>/dev/null | awk 'NR>2 && $1 ~ /tcp/ {print $4}' | awk '!seen[$0]++' | head -n 12 || true)
    fi
    if [[ -z "$lines" ]] && command -v lsof >/dev/null 2>&1; then
        lines=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9, $1}' | awk '!seen[$0]++' | head -n 12 || true)
    fi

    if [[ -n "$lines" ]]; then
        echo -e "${C_DIM}当前本机部分监听端口参考:${C_RESET}"
        echo "$lines" | mask_listen_addr | awk '!seen[$0]++' | sed 's/^/  /'
        echo ""
    fi
}

probe_proxy_ip() {
    local proxy_url="$1"
    local ip=""
    local endpoints=("https://api64.ipify.org" "https://icanhazip.com" "https://ifconfig.me/ip")
    local ep
    for ep in "${endpoints[@]}"; do
        ip=$(printf 'proxy = "%s"\n' "$proxy_url" | curl -K - -fsL --connect-timeout 4 --max-time 6 "$ep" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$ip" ]] && is_valid_ip_literal "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

resolve_port_to_proxy() {
    local raw
    raw=$(normalize_proxy_auth "$1")
    local auth_prefix="${2:-}"
    local hostport=""
    local probed_ip=""

    if [[ "$raw" =~ ^(socks5h?|socks4a?|https?):// ]]; then
        # 将 socks5:// 提醒或保持原协议（推荐 socks5h 防止本地 DNS 泄露）
        echo -e "${C_DIM}正在测试代理连通性: $(mask_proxy_url "$raw") ...${C_RESET}" >&2
        if probed_ip=$(probe_proxy_ip "$raw"); then
            echo -e "${C_GREEN}[成功] 代理连通！出口 IP 预览: $(mask_ip "$probed_ip")${C_RESET}" >&2
            echo "$raw"
            return 0
        else
            echo -e "${C_YELLOW}[警告] 暂未能通过 $(mask_proxy_url "$raw") 获取出口 IP（可能是网络较慢或代理未就绪）。${C_RESET}" >&2
            echo "$raw"
            return 2
        fi
    fi

    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        if (( 10#$raw < 1 || 10#$raw > 65535 )); then
            echo -e "${C_RED}[错误] 端口号必须在 1-65535 之间: $raw${C_RESET}" >&2
            return 1
        fi
        hostport="127.0.0.1:${raw}"
        local listen_info
        listen_info=$(check_local_port_listen "$raw")
        if [[ -z "$listen_info" ]]; then
            echo -e "${C_YELLOW}[提示] 未在本地监听列表中发现端口 ${raw}，仍将尝试连接 127.0.0.1:${raw}...${C_RESET}" >&2
        fi
    else
        if [[ "$raw" =~ :([0-9]+)$ ]]; then
            local extracted_port="${BASH_REMATCH[1]}"
            if (( 10#$extracted_port < 1 || 10#$extracted_port > 65535 )); then
                echo -e "${C_RED}[错误] 端口号必须在 1-65535 之间: $extracted_port${C_RESET}" >&2
                return 1
            fi
        fi
        hostport="$raw"
    fi

    local masked_hp
    masked_hp=$(mask_proxy_url "${auth_prefix}${hostport}")
    echo -e "${C_DIM}正在自动探测 ${masked_hp} 的代理协议 (SOCKS5H / HTTP / HTTPS)...${C_RESET}" >&2
    local proto candidate
    for proto in socks5h http https; do
        candidate="${proto}://${auth_prefix}${hostport}"
        if probed_ip=$(probe_proxy_ip "$candidate"); then
            local proto_upper
            proto_upper=$(echo "$proto" | tr '[:lower:]' '[:upper:]')
            echo -e "${C_GREEN}[成功] 识别为 ${proto_upper} 代理，出口 IP 预览: $(mask_ip "$probed_ip")${C_RESET}" >&2
            echo "$candidate"
            return 0
        fi
    done

    echo -e "${C_RED}[失败] 无法通过 SOCKS5 / HTTP / HTTPS 连接 ${masked_hp}。${C_RESET}" >&2
    echo -e "${C_YELLOW}常见原因排查:${C_RESET}" >&2
    echo "  1. 该端口需要用户名/密码认证（请提供账号密码或完整代理 URL）" >&2
    echo "  2. 该端口是 VLESS/VMess/Trojan/SS 等节点入站，并非直接的 SOCKS5/HTTP 代理端口" >&2
    echo "     -> 如需测试该节点出口，可在面板中开一个本地 SOCKS5/HTTP 出站分流端口，或使用【指定网卡/出口 IP】模式" >&2
    echo "  3. 服务未启动或未监听在目标地址" >&2
    return 1
}

step_select_target() {
    echo -e "${C_BOLD}${C_BLUE}[1/3] 请选择检测目标：${C_RESET}"
    echo -e "  ${C_GREEN}1)${C_RESET} 检测整台机器（默认出口 IP） ${C_DIM}[默认]${C_RESET}"
    echo -e "  ${C_GREEN}2)${C_RESET} 检测指定端口的出口质量（如本地/远程代理端口 21233，支持多端口逗号分隔）"
    echo -e "  ${C_GREEN}3)${C_RESET} 检测指定网卡或指定出口 IP（如 eth0 / warp / wg0 / 1.2.3.4）"
    echo ""

    local choice=""
    tty_read "请输入选项 [1-3] (默认 1): " choice
    choice="${choice:-1}"

    case "$choice" in
        1)
            TARGET_MODE="machine"
            TARGET_PORTS=()
            TARGET_IFACE=""
            ;;
        2)
            TARGET_MODE="port"
            TARGET_IFACE=""
            configure_port_target
            ;;
        3)
            TARGET_MODE="iface"
            TARGET_PORTS=()
            configure_iface_target
            ;;
        *)
            echo -e "${C_YELLOW}无效选项，默认检测整台机器。${C_RESET}"
            TARGET_MODE="machine"
            TARGET_PORTS=()
            TARGET_IFACE=""
            ;;
    esac
    echo ""
}

configure_port_target() {
    echo ""
    show_listening_ports_hint
    echo -e "${C_CYAN}支持输入格式：${C_RESET}"
    echo "  - 纯端口号（自动探测 SOCKS5H/HTTP/HTTPS）: 21233"
    echo "  - 多个端口批量检测（英文逗号分隔）:        21233,21234"
    echo "  - 主机与端口:                              127.0.0.1:21233"
    echo "  - 完整代理地址:                            socks5h://user:pass@127.0.0.1:21233"
    echo ""

    while true; do
        local raw_input=""
        tty_read "请输入端口或代理地址 (输入 b 返回上一步): " raw_input
        raw_input=$(echo "$raw_input" | tr -d '[:space:]')

        if [[ "$raw_input" == "b" || "$raw_input" == "B" ]]; then
            step_select_target
            return
        fi
        if [[ -z "$raw_input" ]]; then
            echo -e "${C_YELLOW}输入不能为空，请重新输入。${C_RESET}"
            continue
        fi

        local auth_prefix=""
        if [[ "$raw_input" != *"://"* && "$raw_input" != *"@"* ]]; then
            local need_auth=""
            tty_read "该端口是否需要代理认证 (用户名/密码)? [y/N]: " need_auth
            if [[ "$need_auth" =~ ^[Yy]$ ]]; then
                local p_user="" p_pass=""
                tty_read "请输入代理用户名: " p_user
                tty_read "请输入代理密码 (输入不回显): " p_pass 1
                if [[ -n "$p_user" ]]; then
                    auth_prefix="$(urlencode_cred "$p_user"):$(urlencode_cred "$p_pass")@"
                fi
            fi
        fi

        TARGET_PORTS=()
        local IFS=','
        local items=($raw_input)
        local item resolved rc all_ok=1

        for item in "${items[@]}"; do
            [[ -z "$item" ]] && continue
            if [[ "$DRY_RUN" -eq 1 ]]; then
                local norm_item
                norm_item=$(normalize_proxy_auth "$item")
                if [[ "$norm_item" =~ ^(socks5h?|socks4a?|https?):// ]]; then
                    TARGET_PORTS+=("$norm_item")
                elif [[ "$norm_item" =~ ^[0-9]+$ ]]; then
                    TARGET_PORTS+=("socks5h://${auth_prefix}127.0.0.1:${norm_item}")
                else
                    TARGET_PORTS+=("socks5h://${auth_prefix}${norm_item}")
                fi
                continue
            fi

            resolved=$(resolve_port_to_proxy "$item" "$auth_prefix")
            rc=$?
            if [[ $rc -eq 0 ]]; then
                TARGET_PORTS+=("$resolved")
            elif [[ $rc -eq 2 ]]; then
                local force_use=""
                tty_read "是否仍然强制使用 $(mask_proxy_url "$resolved") 继续检测? [y/N]: " force_use
                if [[ "$force_use" =~ ^[Yy]$ ]]; then
                    TARGET_PORTS+=("$resolved")
                else
                    all_ok=0
                    break
                fi
            else
                echo ""
                echo -e "可选操作: ${C_GREEN}1)${C_RESET} 重新输入  ${C_GREEN}2)${C_RESET} 手动指定协议强制使用  ${C_GREEN}3)${C_RESET} 改用指定网卡/出口 IP"
                local retry_opt=""
                tty_read "请选择 [1-3] (默认 1): " retry_opt
                case "${retry_opt:-1}" in
                    2)
                        local m_proto=""
                        tty_read "请输入协议 (socks5h / socks5 / http / https，默认 socks5h): " m_proto
                        m_proto="${m_proto:-socks5h}"
                        local norm_item
                        norm_item=$(normalize_proxy_auth "$item")
                        if [[ "$norm_item" =~ ^[0-9]+$ ]]; then
                            TARGET_PORTS+=("${m_proto}://${auth_prefix}127.0.0.1:${norm_item}")
                        else
                            TARGET_PORTS+=("${m_proto}://${auth_prefix}${norm_item}")
                        fi
                        ;;
                    3)
                        TARGET_MODE="iface"
                        TARGET_PORTS=()
                        configure_iface_target
                        return
                        ;;
                    *)
                        all_ok=0
                        break
                        ;;
                esac
            fi
        done

        if [[ $all_ok -eq 1 && ${#TARGET_PORTS[@]} -gt 0 ]]; then
            break
        fi
    done
}

configure_iface_target() {
    echo ""
    local iface_names=()
    local iface_ips=()
    local line if_name if_addr

    if command -v ip >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if_name="${line%% *}"
            if_addr="${line#* }"
            iface_names+=("$if_name")
            iface_ips+=("$if_addr")
        done < <(
            ip -o -4 addr show 2>/dev/null | awk '$2 != "lo" {sub(/@.*/, "", $2); print $2, $4}'
            ip -o -6 addr show scope global 2>/dev/null | awk '$2 != "lo" {sub(/@.*/, "", $2); print $2, $4}'
        )
    elif command -v ifconfig >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if_name="${line%% *}"
            if_addr="${line#* }"
            iface_names+=("$if_name")
            iface_ips+=("$if_addr")
        done < <(
            ifconfig 2>/dev/null | awk '
                /^[a-zA-Z0-9_.-]+:?[[:space:]]/ {
                    iface = $1
                    sub(/:$/, "", iface)
                }
                /inet / && iface != "lo" && iface != "lo0" {
                    addr = $2
                    sub(/^addr:/, "", addr)
                    print iface, addr
                }
                /inet6 / && iface != "lo" && iface != "lo0" {
                    addr = $2
                    if (addr == "addr:") addr = $3
                    sub(/%.*/, "", addr)
                    if (addr !~ /^fe80:/ && addr != "::1") print iface, addr
                }
            '
        )
    fi

    if [[ ${#iface_ips[@]} -gt 0 ]]; then
        echo -e "${C_CYAN}检测到本机以下网卡与出口地址（已自动隐私脱敏显示）：${C_RESET}"
        local idx=1
        local i masked_addr
        for (( i=0; i<${#iface_ips[@]}; i++ )); do
            masked_addr=$(mask_ip "${iface_ips[$i]}")
            echo -e "  ${C_GREEN}${idx})${C_RESET} ${iface_names[$i]} (${masked_addr})"
            idx=$((idx + 1))
        done
        echo ""
    fi

    while true; do
        local iface_input=""
        tty_read "请输入编号、网卡名 (如 eth0/warp) 或出口 IP (输入 b 返回): " iface_input
        iface_input=$(echo "$iface_input" | tr -d '[:space:]')
        if [[ "$iface_input" == "b" || "$iface_input" == "B" ]]; then
            step_select_target
            return
        fi
        if [[ -z "$iface_input" ]]; then
            echo -e "${C_YELLOW}输入不能为空。${C_RESET}"
            continue
        fi
        if [[ "$iface_input" =~ ^[0-9]+$ ]] && (( 10#$iface_input >= 1 && 10#$iface_input <= ${#iface_ips[@]} )); then
            local raw_selected_ip="${iface_ips[$((10#$iface_input - 1))]}"
            TARGET_IFACE="${raw_selected_ip%%/*}"
        else
            TARGET_IFACE="${iface_input%%/*}"
        fi
        break
    done
}

align_iface_ip_stack() {
    [[ "$TARGET_MODE" != "iface" || -z "$TARGET_IFACE" ]] && return 0
    if is_ipv4_literal "$TARGET_IFACE"; then
        if [[ "$IP_STACK" == "6" ]]; then
            echo -e "${C_YELLOW}[提示] 检测到所选出口 ($(mask_ip "$TARGET_IFACE")) 为 IPv4 地址，已自动切换为仅检测 IPv4 (-4)。${C_RESET}"
        fi
        IP_STACK="4"
    elif is_ipv6_literal "$TARGET_IFACE"; then
        if [[ "$IP_STACK" == "4" ]]; then
            echo -e "${C_YELLOW}[提示] 检测到所选出口 ($(mask_ip "$TARGET_IFACE")) 为 IPv6 地址，已自动切换为仅检测 IPv6 (-6)。${C_RESET}"
        fi
        IP_STACK="6"
    fi
}

step_select_privacy() {
    echo -e "${C_BOLD}${C_BLUE}[2/3] 请选择 IP 显示隐私方式（全程纯本地运行，绝不上传任何报告）：${C_RESET}"
    echo -e "  ${C_GREEN}1)${C_RESET} 隐私打码模式：全程隐藏/打码公网 IP (如 203.*.*.55) ${C_DIM}[默认推荐]${C_RESET}"
    echo -e "  ${C_GREEN}2)${C_RESET} 本地完整模式：仅在本地终端展示完整 IP 地址 ${C_DIM}(-f)${C_RESET}"
    echo ""

    local choice=""
    tty_read "请输入选项 [1-2] (默认 1): " choice
    case "${choice:-1}" in
        1|2) PRIVACY_MODE="${choice:-1}" ;;
        *)
            echo -e "${C_YELLOW}无效选项，默认使用隐私打码模式。${C_RESET}"
            PRIVACY_MODE="1"
            ;;
    esac
    echo ""
}

step_select_ip_stack() {
    if [[ "$TARGET_MODE" == "iface" && -n "$TARGET_IFACE" ]]; then
        if is_ipv4_literal "$TARGET_IFACE"; then
            IP_STACK="4"
            echo -e "${C_BOLD}${C_BLUE}[3/3] IP 协议版本：${C_RESET}已指定 IPv4 出口地址，自动锁定为 ${C_GREEN}仅检测 IPv4 (-4)${C_RESET}"
            echo ""
            return
        elif is_ipv6_literal "$TARGET_IFACE"; then
            IP_STACK="6"
            echo -e "${C_BOLD}${C_BLUE}[3/3] IP 协议版本：${C_RESET}已指定 IPv6 出口地址，自动锁定为 ${C_GREEN}仅检测 IPv6 (-6)${C_RESET}"
            echo ""
            return
        fi
    fi

    echo -e "${C_BOLD}${C_BLUE}[3/3] 请选择检测的 IP 协议版本：${C_RESET}"
    echo -e "  ${C_GREEN}1)${C_RESET} 双栈检测 (IPv4 + IPv6) ${C_DIM}[默认]${C_RESET}"
    echo -e "  ${C_GREEN}2)${C_RESET} 仅检测 IPv4 ${C_DIM}(-4)${C_RESET}"
    echo -e "  ${C_GREEN}3)${C_RESET} 仅检测 IPv6 ${C_DIM}(-6)${C_RESET}"
    echo ""

    local choice=""
    tty_read "请输入选项 [1-3] (默认 1): " choice
    case "${choice:-1}" in
        1) IP_STACK="both" ;;
        2) IP_STACK="4" ;;
        3) IP_STACK="6" ;;
        *) IP_STACK="both" ;;
    esac
    echo ""
}

normalize_lang_code() {
    local code
    code=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "$code" in
        cn|zh|zh-cn|zh_cn|chs) echo "cn" ;;
        en|en-us|en_us|eng)    echo "en" ;;
        *)                     return 1 ;;
    esac
    return 0
}

step_advanced_options() {
    echo ""
    echo -e "${C_BOLD}${C_PURPLE}=== 高级选项设置 ===${C_RESET}"

    echo -e "1) 报告语言 (当前: ${C_CYAN}${LANG_CODE}${C_RESET})"
    echo "   可选: cn (中文) | en (English)"
    local lang_in="" norm_lang=""
    tty_read "   请输入语言代码 (直接回车保持 ${LANG_CODE}): " lang_in
    if [[ -n "$lang_in" ]]; then
        if norm_lang=$(normalize_lang_code "$lang_in"); then
            LANG_CODE="$norm_lang"
        else
            echo -e "   ${C_YELLOW}[提示] 支持 cn / en，保持为 ${LANG_CODE}。${C_RESET}"
        fi
    fi

    echo ""
    echo -e "2) 导出报告到本地文件 (当前: ${C_CYAN}${OUTPUT_FILE:-不导出}${C_RESET})"
    echo "   支持后缀: .txt (纯文本) / .ansi (保留终端配色) / .json (JSON数据)"
    echo "   输入 auto 自动按时间戳生成 .txt 文件，输入 none 取消导出"
    local out_in=""
    tty_read "   请输入保存路径 (直接回车保持不变): " out_in
    if [[ "$out_in" == "none" ]]; then
        OUTPUT_FILE=""
    elif [[ "$out_in" == "auto" ]]; then
        OUTPUT_FILE="./ipzhiliang_$(date +%Y%m%d_%H%M%S).txt"
    elif [[ -n "$out_in" ]]; then
        OUTPUT_FILE="$out_in"
    fi

    echo ""
    local json_in=""
    tty_read "3) 是否在终端以纯 JSON 格式输出? [y/N] (当前: $([[ $JSON_MODE -eq 1 ]] && echo 是 || echo 否)): " json_in
    if [[ "$json_in" =~ ^[Yy]$ ]]; then
        JSON_MODE=1
    elif [[ "$json_in" =~ ^[Nn]$ ]]; then
        JSON_MODE=0
    fi

    echo ""
    local media_in=""
    tty_read "4) 是否检测 AI 与流媒体解锁? [Y/n] (当前: $([[ $SKIP_MEDIA -eq 0 ]] && echo 开启 || echo 关闭)): " media_in
    if [[ "$media_in" =~ ^[Nn]$ ]]; then
        SKIP_MEDIA=1
    elif [[ "$media_in" =~ ^[Yy]$ ]]; then
        SKIP_MEDIA=0
    fi

    echo ""
    local mail_in=""
    local mail_state_txt="默认跳过-防云商25端口风控"
    [[ "$MAIL_MODE" == "enable" ]] && mail_state_txt="开启"
    [[ "$MAIL_MODE" == "skip_user" ]] && mail_state_txt="已关闭"
    tty_read "5) 是否主动探测 25 端口邮局出站? [y/N] (当前: ${mail_state_txt}): " mail_in
    if [[ "$mail_in" =~ ^[Yy]$ ]]; then
        MAIL_MODE="enable"
    elif [[ "$mail_in" =~ ^[Nn]$ ]]; then
        MAIL_MODE="skip_user"
    fi

    echo ""
    local keys_in=""
    local keys_state_txt="未配置(仅用9大免Key内置库)"
    has_any_byok_keys && keys_state_txt="已配置部分扩展库Key"
    tty_read "6) 是否查看/配置免费扩展数据库 API Key (ipapi.is/AbuseIPDB/ipdata/IPQS/MaxMind)? [y/N] (当前: ${keys_state_txt}): " keys_in
    if [[ "$keys_in" =~ ^[Yy]$ ]]; then
        configure_api_keys_interactive
    fi
    echo ""
}

show_summary() {
    align_iface_ip_stack
    echo -e "${C_BOLD}${C_CYAN}====================== 检测配置总览 ======================${C_RESET}"
    case "$TARGET_MODE" in
        machine)
            echo -e "  检测目标: ${C_GREEN}整台机器默认出口${C_RESET}"
            ;;
        port)
            local masked_list=()
            local p
            for p in "${TARGET_PORTS[@]}"; do
                masked_list+=("$(mask_proxy_url "$p")")
            done
            echo -e "  检测目标: ${C_GREEN}指定端口/代理 (${#TARGET_PORTS[@]} 个)${C_RESET} -> ${masked_list[*]}"
            ;;
        iface)
            echo -e "  检测目标: ${C_GREEN}指定网卡/出口 IP${C_RESET} -> $(format_iface_display "$TARGET_IFACE")"
            ;;
    esac

    if [[ "$PRIVACY_MODE" == "1" ]]; then
        echo -e "  隐私模式: ${C_GREEN}隐私打码 (隐藏 IP · 纯本地零上传)${C_RESET}"
    else
        echo -e "  隐私模式: ${C_GREEN}本地完整 (展示完整 IP · 纯本地零上传)${C_RESET}"
    fi

    local stack_label="双栈 (IPv4 + IPv6)"
    [[ "$IP_STACK" == "4" ]] && stack_label="仅 IPv4"
    [[ "$IP_STACK" == "6" ]] && stack_label="仅 IPv6"
    echo -e "  协议版本: ${stack_label}"
    echo -e "  报告语言: ${LANG_CODE}"
    [[ -n "$OUTPUT_FILE" ]] && echo -e "  导出文件: ${OUTPUT_FILE} (0600 权限)"
    [[ "$JSON_MODE" -eq 1 ]] && echo -e "  JSON输出: 开启"
    [[ "$SKIP_MEDIA" -eq 1 ]] && echo -e "  流媒体/AI: 跳过"
    if [[ "$MAIL_MODE" == "enable" ]]; then
        echo -e "  25端口检测: ${C_YELLOW}开启 (主动外连探测)${C_RESET}"
    elif [[ "$MAIL_MODE" == "skip_user" ]]; then
        echo -e "  25端口检测: 跳过"
    fi
    local byok_names=""
    [[ -n "${IPAPI_IS_API_KEY:-}" ]]    && byok_names="${byok_names}${byok_names:+, }ipapi.is"
    [[ -n "${ABUSEIPDB_API_KEY:-}" ]]   && byok_names="${byok_names}${byok_names:+, }AbuseIPDB"
    [[ -n "${IPDATA_API_KEY:-}" ]]      && byok_names="${byok_names}${byok_names:+, }ipdata"
    [[ -n "${IPQS_API_KEY:-}" ]]        && byok_names="${byok_names}${byok_names:+, }IPQS"
    [[ -n "${MAXMIND_ACCOUNT_ID:-}" && -n "${MAXMIND_LICENSE_KEY:-}" ]] && byok_names="${byok_names}${byok_names:+, }MaxMind"
    [[ -n "${IP2LOCATION_API_KEY:-}" ]] && byok_names="${byok_names}${byok_names:+, }IP2Location"
    [[ -n "${IPREGISTRY_API_KEY:-}" ]]  && byok_names="${byok_names}${byok_names:+, }ipregistry"
    [[ -n "${DBIP_API_KEY:-}" ]]        && byok_names="${byok_names}${byok_names:+, }DB-IP"
    if [[ -n "$byok_names" ]]; then
        echo -e "  自有Key:  ${C_GREEN}${byok_names}${C_RESET}"
    fi
    echo -e "${C_BOLD}${C_CYAN}==========================================================${C_RESET}"
}

# ==============================================================================
# 地理信息本地化（纯本地 ISO-3166 国家/洲际映射与 DMS 度分秒坐标转换，零外链依赖）
# ==============================================================================

format_dms() {
    local lat="$1" lon="$2"
    [[ -z "$lat" || -z "$lon" || "$lat" == "null" || "$lon" == "null" ]] && return
    awk -v lat="$lat" -v lon="$lon" '
        function to_dms(v, pos, neg,    dir, deg, rem, min, sec) {
            dir = pos
            if (v < 0) { dir = neg; v = -v }
            deg = int(v)
            rem = (v - deg) * 60
            min = int(rem)
            sec = int((rem - min) * 60 + 0.5)
            if (sec >= 60) { sec = 0; min++ }
            if (min >= 60) { min = 0; deg++ }
            return sprintf("%d°%d′%d″%s", deg, min, sec, dir)
        }
        BEGIN {
            if (lat !~ /^-?[0-9]+(\.[0-9]+)?$/ || lon !~ /^-?[0-9]+(\.[0-9]+)?$/) exit 1
            printf "%s, %s", to_dms(lon + 0, "E", "W"), to_dms(lat + 0, "N", "S")
        }
    ' 2>/dev/null || true
}

format_map_url() {
    local lat="$1" lon="$2"
    [[ -z "$lat" || -z "$lon" || "$lat" == "null" || "$lon" == "null" ]] && return
    awk -v lat="$lat" -v lon="$lon" '
        BEGIN {
            if (lat !~ /^-?[0-9]+(\.[0-9]+)?$/ || lon !~ /^-?[0-9]+(\.[0-9]+)?$/) exit 1
            printf "https://maps.google.com/?q=%.4f,%.4f", lat + 0, lon + 0
        }
    ' 2>/dev/null || true
}

lookup_continent_name() {
    local code
    code=$(echo "${1:-}" | tr '[:lower:]' '[:upper:]')
    if [[ "$LANG_CODE" == "en" ]]; then
        case "$code" in
            AS) echo "Asia" ;;
            EU) echo "Europe" ;;
            NA) echo "North America" ;;
            SA) echo "South America" ;;
            OC) echo "Oceania" ;;
            AF) echo "Africa" ;;
            AN) echo "Antarctica" ;;
            *)  echo "" ;;
        esac
    else
        case "$code" in
            AS) echo "亚洲" ;;
            EU) echo "欧洲" ;;
            NA) echo "北美洲" ;;
            SA) echo "南美洲" ;;
            OC) echo "大洋洲" ;;
            AF) echo "非洲" ;;
            AN) echo "南极洲" ;;
            *)  echo "" ;;
        esac
    fi
}

lookup_continent_from_cc() {
    local cc
    cc=$(echo "${1:-}" | tr '[:lower:]' '[:upper:]')
    case "$cc" in
        AF|AM|AZ|BH|BD|BT|BN|KH|CN|CY|GE|HK|IN|ID|IR|IQ|IL|JP|JO|KZ|KW|KG|LA|LB|MO|MY|MV|MN|MM|NP|KP|OM|PK|PS|PH|QA|SA|SG|KR|LK|SY|TW|TJ|TH|TL|TR|TM|AE|UZ|VN|YE) echo "AS" ;;
        AL|AD|AT|BY|BE|BA|BG|HR|CZ|DK|EE|FO|FI|FR|DE|GI|GR|GG|HU|IS|IE|IM|IT|JE|XK|LV|LI|LT|LU|MT|MD|MC|ME|NL|MK|NO|PL|PT|RO|RU|SM|RS|SK|SI|ES|SJ|SE|CH|UA|GB|VA|AX) echo "EU" ;;
        AG|AI|AW|BS|BB|BZ|BM|BQ|VG|CA|KY|CR|CU|CW|DM|DO|SV|GL|GD|GP|GT|HT|HN|JM|MQ|MX|MS|NI|PA|PR|BL|KN|LC|MF|PM|VC|SX|TT|TC|US|VI) echo "NA" ;;
        AR|BO|BR|CL|CO|EC|FK|GF|GY|PY|PE|SR|UY|VE) echo "SA" ;;
        AS|AU|CK|FJ|PF|GU|KI|MH|FM|NR|NC|NZ|NU|NF|MP|PW|PG|PN|WS|SB|TK|TO|TV|UM|VU|WF) echo "OC" ;;
        DZ|AO|BJ|BW|BF|BI|CV|CM|CF|TD|KM|CG|CD|CI|DJ|EG|GQ|ER|SZ|ET|GA|GM|GH|GN|GW|KE|LS|LR|LY|MG|MW|ML|MR|MU|YT|MA|MZ|NA|NE|NG|RE|RW|SH|ST|SN|SC|SL|SO|ZA|SS|SD|TZ|TG|TN|UG|EH|ZM|ZW) echo "AF" ;;
        AQ|BV|TF|HM|GS) echo "AN" ;;
        *) echo "" ;;
    esac
}

lookup_country_cn() {
    local cc
    cc=$(echo "${1:-}" | tr '[:lower:]' '[:upper:]')
    case "$cc" in
        US) echo "美国" ;; CN) echo "中国" ;; HK) echo "中国香港" ;; TW) echo "中国台湾" ;; MO) echo "中国澳门" ;;
        JP) echo "日本" ;; SG) echo "新加坡" ;; KR) echo "韩国" ;; GB) echo "英国" ;; DE) echo "德国" ;;
        FR) echo "法国" ;; NL) echo "荷兰" ;; CA) echo "加拿大" ;; AU) echo "澳大利亚" ;; RU) echo "俄罗斯" ;;
        IN) echo "印度" ;; BR) echo "巴西" ;; IT) echo "意大利" ;; ES) echo "西班牙" ;; CH) echo "瑞士" ;;
        SE) echo "瑞典" ;; NO) echo "挪威" ;; FI) echo "芬兰" ;; DK) echo "丹麦" ;; PL) echo "波兰" ;;
        AT) echo "奥地利" ;; BE) echo "比利时" ;; IE) echo "爱尔兰" ;; PT) echo "葡萄牙" ;; CZ) echo "捷克" ;;
        LU) echo "卢森堡" ;; RO) echo "罗马尼亚" ;; BG) echo "保加利亚" ;; HU) echo "匈牙利" ;; GR) echo "希腊" ;;
        TR) echo "土耳其" ;; UA) echo "乌克兰" ;; BY) echo "白俄罗斯" ;; KZ) echo "哈萨克斯坦" ;; VN) echo "越南" ;;
        TH) echo "泰国" ;; MY) echo "马来西亚" ;; ID) echo "印度尼西亚" ;; PH) echo "菲律宾" ;; NZ) echo "新西兰" ;;
        MX) echo "墨西哥" ;; AR) echo "阿根廷" ;; CL) echo "智利" ;; CO) echo "哥伦比亚" ;; PE) echo "秘鲁" ;;
        ZA) echo "南非" ;; EG) echo "埃及" ;; NG) echo "尼日利亚" ;; KE) echo "肯尼亚" ;; MA) echo "摩洛哥" ;;
        AE) echo "阿联酋" ;; SA) echo "沙特阿拉伯" ;; IL) echo "以色列" ;; QA) echo "卡塔尔" ;; KW) echo "科威特" ;;
        BH) echo "巴林" ;; OM) echo "阿曼" ;; JO) echo "约旦" ;; PK) echo "巴基斯坦" ;; BD) echo "孟加拉国" ;;
        LK) echo "斯里兰卡" ;; NP) echo "尼泊尔" ;; MM) echo "缅甸" ;; KH) echo "柬埔寨" ;; LA) echo "老挝" ;;
        MN) echo "蒙古" ;; KP) echo "朝鲜" ;; IR) echo "伊朗" ;; IQ) echo "伊拉克" ;; SY) echo "叙利亚" ;;
        AF) echo "阿富汗" ;; UZ) echo "乌兹别克斯坦" ;; AZ) echo "阿塞拜疆" ;; GE) echo "格鲁吉亚" ;; AM) echo "亚美尼亚" ;;
        CY) echo "塞浦路斯" ;; MT) echo "马耳他" ;; IS) echo "冰岛" ;; SK) echo "斯洛伐克" ;; SI) echo "斯洛文尼亚" ;;
        HR) echo "克罗地亚" ;; RS) echo "塞尔维亚" ;; BA) echo "波黑" ;; ME) echo "黑山" ;; AL) echo "阿尔巴尼亚" ;;
        MK) echo "北马其顿" ;; MD) echo "摩尔多瓦" ;; EE) echo "爱沙尼亚" ;; LV) echo "拉脱维亚" ;; LT) echo "立陶宛" ;;
        MC) echo "摩纳哥" ;; LI) echo "列支敦士登" ;; AD) echo "安道尔" ;; SM) echo "圣马力诺" ;; GI) echo "直布罗陀" ;;
        PA) echo "巴拿马" ;; CR) echo "哥斯达黎加" ;; UY) echo "乌拉圭" ;; PY) echo "巴拉圭" ;; EC) echo "厄瓜多尔" ;;
        BO) echo "玻利维亚" ;; VE) echo "委内瑞拉" ;; CU) echo "古巴" ;; DO) echo "多米尼加" ;; PR) echo "波多黎各" ;;
        JM) echo "牙买加" ;; BS) echo "巴哈马" ;; KY) echo "开曼群岛" ;; VG) echo "英属维尔京群岛" ;; BM) echo "百慕大" ;;
        SC) echo "塞舌尔" ;; MU) echo "毛里求斯" ;; TN) echo "突尼斯" ;; DZ) echo "阿尔及利亚" ;; GH) echo "加纳" ;;
        ET) echo "埃塞俄比亚" ;; TZ) echo "坦桑尼亚" ;; UG) echo "乌干达" ;; AO) echo "安哥拉" ;; ZW) echo "津巴布韦" ;;
        GT) echo "危地马拉" ;; HN) echo "洪都拉斯" ;; SV) echo "萨尔瓦多" ;; NI) echo "尼加拉瓜" ;; BZ) echo "伯利兹" ;;
        BN) echo "文莱" ;; MV) echo "马尔代夫" ;; BT) echo "不丹" ;; KG) echo "吉尔吉斯斯坦" ;; TJ) echo "塔吉克斯坦" ;;
        TM) echo "土库曼斯坦" ;; LB) echo "黎巴嫩" ;; YE) echo "也门" ;; PS) echo "巴勒斯坦" ;; FJ) echo "斐济" ;;
        PG) echo "巴布亚新几内亚" ;; GU) echo "关岛" ;; GL) echo "格陵兰" ;; FO) echo "法罗群岛" ;; IM) echo "马恩岛" ;;
        JE) echo "泽西岛" ;; GG) echo "根西岛" ;; CW) echo "库拉索" ;; AW) echo "阿鲁巴" ;; TT) echo "特立尼达和多巴哥" ;;
        *) echo "" ;;
    esac
}

lookup_country_en() {
    local cc
    cc=$(echo "${1:-}" | tr '[:lower:]' '[:upper:]')
    case "$cc" in
        US) echo "United States" ;; CN) echo "China" ;; HK) echo "Hong Kong" ;; TW) echo "Taiwan" ;; MO) echo "Macao" ;;
        JP) echo "Japan" ;; SG) echo "Singapore" ;; KR) echo "South Korea" ;; GB) echo "United Kingdom" ;; DE) echo "Germany" ;;
        FR) echo "France" ;; NL) echo "Netherlands" ;; CA) echo "Canada" ;; AU) echo "Australia" ;; RU) echo "Russia" ;;
        IN) echo "India" ;; BR) echo "Brazil" ;; IT) echo "Italy" ;; ES) echo "Spain" ;; CH) echo "Switzerland" ;;
        SE) echo "Sweden" ;; NO) echo "Norway" ;; FI) echo "Finland" ;; DK) echo "Denmark" ;; PL) echo "Poland" ;;
        AT) echo "Austria" ;; BE) echo "Belgium" ;; IE) echo "Ireland" ;; PT) echo "Portugal" ;; CZ) echo "Czechia" ;;
        LU) echo "Luxembourg" ;; RO) echo "Romania" ;; BG) echo "Bulgaria" ;; HU) echo "Hungary" ;; GR) echo "Greece" ;;
        TR) echo "Turkey" ;; UA) echo "Ukraine" ;; BY) echo "Belarus" ;; KZ) echo "Kazakhstan" ;; VN) echo "Vietnam" ;;
        TH) echo "Thailand" ;; MY) echo "Malaysia" ;; ID) echo "Indonesia" ;; PH) echo "Philippines" ;; NZ) echo "New Zealand" ;;
        MX) echo "Mexico" ;; AR) echo "Argentina" ;; CL) echo "Chile" ;; CO) echo "Colombia" ;; PE) echo "Peru" ;;
        ZA) echo "South Africa" ;; EG) echo "Egypt" ;; NG) echo "Nigeria" ;; KE) echo "Kenya" ;; MA) echo "Morocco" ;;
        AE) echo "United Arab Emirates" ;; SA) echo "Saudi Arabia" ;; IL) echo "Israel" ;; QA) echo "Qatar" ;; KW) echo "Kuwait" ;;
        CY) echo "Cyprus" ;; MT) echo "Malta" ;; IS) echo "Iceland" ;; SK) echo "Slovakia" ;; SI) echo "Slovenia" ;;
        HR) echo "Croatia" ;; RS) echo "Serbia" ;; EE) echo "Estonia" ;; LV) echo "Latvia" ;; LT) echo "Lithuania" ;;
        PA) echo "Panama" ;; SC) echo "Seychelles" ;; MU) echo "Mauritius" ;; MD) echo "Moldova" ;; GE) echo "Georgia" ;;
        *) echo "" ;;
    esac
}

format_country_display() {
    local cc="$1"
    local api_name="${2:-}"
    local localized=""
    if [[ "$LANG_CODE" == "en" ]]; then
        localized=$(lookup_country_en "$cc")
        [[ -z "$localized" ]] && localized="$api_name"
        if [[ -n "$localized" && "$localized" != "N/A" ]]; then
            echo "[${cc}] ${localized}"
        else
            echo "[${cc}]"
        fi
    else
        localized=$(lookup_country_cn "$cc")
        [[ -z "$localized" ]] && localized="$api_name"
        if [[ -n "$localized" && "$localized" != "N/A" ]]; then
            echo "[${cc}]${localized}"
        else
            echo "[${cc}]"
        fi
    fi
}

# ==============================================================================
# 独立自研核心检测引擎：Phase 1 多源情报并行查询
# ==============================================================================

# 统一隔离直连抓取（所有数据库查询严格遵守代理/网卡隔离，绝不泄露宿主机 IP）
curl_fetch_raw() {
    local -a opts=()
    if [[ -n "$ACTIVE_CURL_CFG" && -f "$ACTIVE_CURL_CFG" ]]; then
        opts+=("-K" "$ACTIVE_CURL_CFG")
    elif [[ -n "$ACTIVE_IFACE" ]]; then
        opts+=("--interface" "$ACTIVE_IFACE")
        if is_ipv6_literal "$ACTIVE_IFACE"; then
            opts+=("-6")
        elif is_ipv4_literal "$ACTIVE_IFACE"; then
            opts+=("-4")
        fi
    fi
    curl ${opts[@]+"${opts[@]}"} "$@"
}

# 通用拉取工具：根据模式严格通过代理或指定网卡请求（IPv6 直连若目标 API 无 AAAA 则自动兼容）
fetch_db_json() {
    local url="$1"
    local stack="$2"
    local out_file="$3"
    local resp=""

    resp=$(curl_fetch_raw -fsL --connect-timeout 4 --max-time 8 -A "$UA_CHROME" "$url" 2>/dev/null || true)
    if [[ -n "$resp" ]] && echo "$resp" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$resp" > "$out_file"
    else
        printf '{}' > "$out_file"
    fi
}

# ipregistry 官方直连（支持自有 IPREGISTRY_API_KEY；否则使用官网公开 Demo Key 并在失效时自动刷新）
fetch_ipregistry_data() {
    local ip="$1"
    local stack="$2"
    local out_file="$3"
    local resp=""

    if [[ -n "${IPREGISTRY_API_KEY:-}" ]]; then
        resp=$(printf 'header = "Authorization: ApiKey %s"\n' "$IPREGISTRY_API_KEY" | \
            curl_fetch_raw -K - -fsL --compressed --connect-timeout 4 --max-time 8 -A "$UA_CHROME" \
            "https://api.ipregistry.co/${ip}?hostname=true" 2>/dev/null || true)
        if [[ -n "$resp" ]] && echo "$resp" | jq -e '.ip' >/dev/null 2>&1; then
            printf '%s' "$resp" > "$out_file"
            return
        fi
    fi

    local demo_key="sb69ksjcajfs4c"
    resp=$(curl_fetch_raw -fsL --compressed --connect-timeout 4 --max-time 8 \
        -H "Origin: https://ipregistry.co" \
        -H "Referer: https://ipregistry.co/" \
        -A "$UA_CHROME" \
        "https://api.ipregistry.co/${ip}?hostname=true&key=${demo_key}" 2>/dev/null || true)

    if [[ -z "$resp" ]] || ! echo "$resp" | jq -e '.ip' >/dev/null 2>&1; then
        local html fresh_key=""
        html=$(curl_fetch_raw -fsL --connect-timeout 4 --max-time 7 -A "$UA_CHROME" "https://ipregistry.co" 2>/dev/null || true)
        fresh_key=$(echo "$html" | grep -oE 'apiKey="[a-zA-Z0-9_-]+"' | head -n1 | cut -d'"' -f2 || true)
        if [[ -n "$fresh_key" && "$fresh_key" != "$demo_key" ]]; then
            resp=$(curl_fetch_raw -fsL --compressed --connect-timeout 4 --max-time 8 \
                -H "Origin: https://ipregistry.co" \
                -H "Referer: https://ipregistry.co/" \
                -A "$UA_CHROME" \
                "https://api.ipregistry.co/${ip}?hostname=true&key=${fresh_key}" 2>/dev/null || true)
        fi
    fi

    if [[ -n "$resp" ]] && echo "$resp" | jq -e '.ip' >/dev/null 2>&1; then
        printf '%s' "$resp" > "$out_file"
    else
        printf '{}' > "$out_file"
    fi
}

# IP2Location 完整 PX12 直连（优先自有 IP2LOCATION_API_KEY -> 其次官方演示页内嵌完整 PX12 JSON -> 自动回退 api.ip2location.io）
fetch_ip2location_data() {
    local ip="$1"
    local stack="$2"
    local out_file="$3"
    local resp=""

    if [[ -n "${IP2LOCATION_API_KEY:-}" ]]; then
        resp=$(printf 'url = "https://api.ip2location.io/?key=%s&ip=%s&format=json"\n' "$IP2LOCATION_API_KEY" "$ip" | \
            curl_fetch_raw -K - -fsL --connect-timeout 4 --max-time 8 -A "$UA_CHROME" 2>/dev/null || true)
        if [[ -n "$resp" ]] && echo "$resp" | jq -e '.ip' >/dev/null 2>&1; then
            printf '%s' "$resp" > "$out_file"
            return
        fi
    fi

    local html extracted=""
    html=$(curl_fetch_raw -fsL --compressed --connect-timeout 4 --max-time 9 -A "$UA_CHROME" "https://www.ip2location.com/demo/${ip}" 2>/dev/null || true)
    if [[ -n "$html" ]]; then
        extracted=$(printf '%s\n' "$html" | awk '
            /class="language-json"/ { in_json=1; sub(/.*class="language-json">/, "") }
            in_json {
                if (/<\/code>/) {
                    sub(/<\/code>.*/, "")
                    print
                    exit
                }
                print
            }
        ' | sed "s/&amp;/\\&/g; s/&quot;/\"/g; s/&#039;/'/g; s/&lt;/</g; s/&gt;/>/g")
        if [[ -n "$extracted" ]] && echo "$extracted" | jq -e '.ip' >/dev/null 2>&1; then
            printf '%s' "$extracted" > "$out_file"
            return
        fi
    fi

    # 回退到 api.ip2location.io 免 Key 基础接口
    fetch_db_json "https://api.ip2location.io/?ip=${ip}" "$stack" "$out_file"
}

# DB-IP 官方直连（优先自有 DBIP_API_KEY -> 其次官方公开 Demo 接口拿威胁评级/代理/爬虫 -> 超限自动回退 /v2/free/）
fetch_dbip_data() {
    local ip="$1"
    local stack="$2"
    local out_file="$3"
    local resp=""

    if [[ -n "${DBIP_API_KEY:-}" ]]; then
        resp=$(printf 'url = "https://api.db-ip.com/v2/%s/%s"\n' "$DBIP_API_KEY" "$ip" | \
            curl_fetch_raw -K - -fsL --connect-timeout 4 --max-time 8 -A "$UA_CHROME" 2>/dev/null || true)
        if [[ -n "$resp" ]] && echo "$resp" | jq -e '.countryCode and (.errorCode == null)' >/dev/null 2>&1; then
            printf '%s' "$resp" > "$out_file"
            return
        fi
    fi

    # 尝试官方公开 Core Demo 接口（有每日共享额度，若命中则含 threatLevel/isProxy/isCrawler）
    local core_html demo_key=""
    core_html=$(curl_fetch_raw -fsL --connect-timeout 3 --max-time 6 -A "$UA_CHROME" "https://db-ip.com/api/core/" 2>/dev/null || true)
    demo_key=$(echo "$core_html" | sed -n 's/.*data-api-key="\([^"]*\)".*/\1/p' | head -n1 || true)
    if [[ -n "$demo_key" ]]; then
        resp=$(curl_fetch_raw -fsL --connect-timeout 3 --max-time 6 \
            -H "Origin: https://db-ip.com" \
            -H "Referer: https://db-ip.com/" \
            -A "$UA_CHROME" \
            "https://api.db-ip.com/v2/${demo_key}/${ip}" 2>/dev/null || true)
        if [[ -n "$resp" ]] && echo "$resp" | jq -e '.countryCode and (.errorCode == null)' >/dev/null 2>&1; then
            printf '%s' "$resp" > "$out_file"
            return
        fi
    fi

    # 回退至 DB-IP 官方免费无限制基础接口（提供地区/洲际/省市）
    fetch_db_json "https://api.db-ip.com/v2/free/${ip}" "$stack" "$out_file"
}

fetch_scamalytics_data() {
    local ip="$1"
    local out_file="$2"
    local html=""

    html=$(curl_fetch_raw -fsL --connect-timeout 4 --max-time 9 -A "$UA_CHROME" "https://scamalytics.com/ip/${ip}" 2>/dev/null || true)

    if [[ -z "$html" ]]; then
        printf '{}' > "$out_file"
        return
    fi

    local score risk cc vpn tor server proxy robot abuser hostname lat lon postal city region
    score=$(echo "$html" | grep -oE '"score":"[0-9]+"' | head -n1 | grep -oE '[0-9]+' || true)
    risk=$(echo "$html" | grep -oE '"risk":"[^"]+"' | head -n1 | cut -d'"' -f4 || true)

    local parsed
    parsed=$(echo "$html" | awk '
        /<th>/ { h = $0 }
        /<td>/ {
            row = h " => " $0
            gsub(/<[^>]*>/, " ", row)
            gsub(/[[:space:]]+/, " ", row)
            print row
        }
    ')

    cc=$(echo "$parsed" | awk -F'=>' '/Country Code/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')
    hostname=$(echo "$parsed" | awk -F'=>' '/Hostname/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if (tolower($2)!="n/a") print $2; exit}')
    region=$(echo "$parsed" | awk -F'=>' '/State \/ Province/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if (tolower($2)!="n/a") print $2; exit}')
    city=$(echo "$parsed" | awk -F'=>' '/ City / {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if (tolower($2)!="n/a") print $2; exit}')
    postal=$(echo "$parsed" | awk -F'=>' '/Postal Code/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if (tolower($2)!="n/a") print $2; exit}')
    lat=$(echo "$parsed" | awk -F'=>' '/Latitude/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if (tolower($2)!="n/a") print $2; exit}')
    lon=$(echo "$parsed" | awk -F'=>' '/Longitude/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if (tolower($2)!="n/a") print $2; exit}')

    vpn=$(echo "$parsed" | awk -F'=>' '/Anonymizing VPN/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print tolower($2); exit}')
    tor=$(echo "$parsed" | awk -F'=>' '/Tor Exit Node/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print tolower($2); exit}')
    server=$(echo "$parsed" | awk -F'=>' '/ Server / {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print tolower($2); exit}')
    proxy=$(echo "$parsed" | awk -F'=>' '/Public Proxy|Web Proxy|Residential Proxy/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if (tolower($2)=="yes") {print "yes"; exit}} END{}')
    if [[ -z "$proxy" ]] && echo "$parsed" | grep -q "Public Proxy"; then
        proxy="no"
    fi
    abuser=$(echo "$parsed" | awk -F'=>' '/Firehol|IP2ProxyLite|IPsum|Spamhaus|X4Bnet Spambot/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if (tolower($2)=="yes") {print "yes"; exit}} END{}')
    if [[ -z "$abuser" ]] && echo "$parsed" | grep -qE "Firehol|Spamhaus|IPsum"; then
        abuser="no"
    fi
    robot=$(echo "$parsed" | awk -F'=>' '/Search Engine Robot|X4Bnet Spambot/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if (tolower($2)=="yes") {print "yes"; exit}} END{}')
    if [[ -z "$robot" ]] && echo "$parsed" | grep -q "Search Engine Robot"; then
        robot="no"
    fi

    [[ "$vpn" == "yes" ]] && vpn="true" || { [[ "$vpn" == "no" ]] && vpn="false" || vpn="null"; }
    [[ "$tor" == "yes" ]] && tor="true" || { [[ "$tor" == "no" ]] && tor="false" || tor="null"; }
    [[ "$server" == "yes" ]] && server="true" || { [[ "$server" == "no" ]] && server="false" || server="null"; }
    [[ "$proxy" == "yes" ]] && proxy="true" || { [[ "$proxy" == "no" ]] && proxy="false" || proxy="null"; }
    [[ "$abuser" == "yes" ]] && abuser="true" || { [[ "$abuser" == "no" ]] && abuser="false" || abuser="null"; }
    [[ "$robot" == "yes" ]] && robot="true" || { [[ "$robot" == "no" ]] && robot="false" || robot="null"; }

    jq -n \
        --arg score "${score:-}" \
        --arg risk "${risk:-}" \
        --arg cc "${cc:-}" \
        --arg hostname "${hostname:-}" \
        --arg region "${region:-}" \
        --arg city "${city:-}" \
        --arg postal "${postal:-}" \
        --arg lat "${lat:-}" \
        --arg lon "${lon:-}" \
        --arg vpn "$vpn" \
        --arg tor "$tor" \
        --arg server "$server" \
        --arg proxy "$proxy" \
        --arg abuser "$abuser" \
        --arg robot "$robot" \
        '{score: $score, risk: $risk, country: $cc, hostname: $hostname, region: $region, city: $city, postal: $postal, lat: $lat, lon: $lon, vpn: $vpn, tor: $tor, server: $server, proxy: $proxy, abuser: $abuser, robot: $robot}' > "$out_file"
}

fetch_optional_byok() {
    local ip="$1"
    local workdir="$2"

    # 可选 ipapi.is（免费 1,000 次/天，通过 curl -K - 传递含 Key 的 URL 防 ps aux 泄露）
    if [[ -n "${IPAPI_IS_API_KEY:-}" ]]; then
        local resp=""
        resp=$(printf 'url = "https://api.ipapi.is/?q=%s&key=%s"\n' "$ip" "$IPAPI_IS_API_KEY" | \
            curl_fetch_raw -K - -fsL --connect-timeout 4 --max-time 8 -A "$UA_CHROME" 2>/dev/null || true)
        if [[ -n "$resp" ]] && echo "$resp" | jq -e '(.asn | type) == "object" or (.is_datacenter != null)' >/dev/null 2>&1; then
            printf '%s' "$resp" > "${workdir}/db_ipapi_is.json"
        fi
    fi

    # 可选 AbuseIPDB（免费 1,000 次/天，通过 stdin header 传递 API Key 防 ps aux 泄露）
    if [[ -n "${ABUSEIPDB_API_KEY:-}" ]]; then
        local resp=""
        resp=$(printf 'header = "Key: %s"\nheader = "Accept: application/json"\n' "$ABUSEIPDB_API_KEY" | \
            curl_fetch_raw -K - -fsL --connect-timeout 4 --max-time 8 \
            "https://api.abuseipdb.com/api/v2/check?ipAddress=${ip}&maxAgeInDays=90" 2>/dev/null || true)
        if [[ -n "$resp" ]] && echo "$resp" | jq -e '.data' >/dev/null 2>&1; then
            printf '%s' "$resp" > "${workdir}/db_abuseipdb.json"
        fi
    fi

    # 可选 ipdata（免费 1,500 次/天，通过 curl -K - 传递 URL 防 ps aux 泄露）
    if [[ -n "${IPDATA_API_KEY:-}" ]]; then
        local resp=""
        resp=$(printf 'url = "https://api.ipdata.co/%s?api-key=%s"\n' "$ip" "$IPDATA_API_KEY" | \
            curl_fetch_raw -K - -fsL --connect-timeout 4 --max-time 8 -A "$UA_CHROME" 2>/dev/null || true)
        if [[ -n "$resp" ]] && echo "$resp" | jq -e '.threat != null or .country_code != null' >/dev/null 2>&1; then
            printf '%s' "$resp" > "${workdir}/db_ipdata.json"
        fi
    fi

    # 可选 IPQualityScore（免费 5,000 次/月，通过 curl -K - 传递 URL 防 ps aux 泄露）
    if [[ -n "${IPQS_API_KEY:-}" ]]; then
        local resp=""
        resp=$(printf 'url = "https://www.ipqualityscore.com/api/json/ip/%s/%s?strictness=1"\n' "$IPQS_API_KEY" "$ip" | \
            curl_fetch_raw -K - -fsL --connect-timeout 4 --max-time 8 2>/dev/null || true)
        if [[ -n "$resp" ]] && echo "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
            printf '%s' "$resp" > "${workdir}/db_ipqs.json"
        fi
    fi

    # 可选 MaxMind GeoLite2 / GeoIP2 官方 Web Services（通过 stdin user 字段传 Basic Auth）
    if [[ -n "${MAXMIND_ACCOUNT_ID:-}" && -n "${MAXMIND_LICENSE_KEY:-}" ]]; then
        local resp=""
        resp=$(printf 'user = "%s:%s"\n' "$MAXMIND_ACCOUNT_ID" "$MAXMIND_LICENSE_KEY" | \
            curl_fetch_raw -K - -fsL --connect-timeout 4 --max-time 8 \
            "https://geolite.info/geoip/v2.1/city/${ip}" 2>/dev/null || true)
        if [[ -z "$resp" ]] || ! echo "$resp" | jq -e '.country != null or .traits != null' >/dev/null 2>&1; then
            resp=$(printf 'user = "%s:%s"\n' "$MAXMIND_ACCOUNT_ID" "$MAXMIND_LICENSE_KEY" | \
                curl_fetch_raw -K - -fsL --connect-timeout 4 --max-time 8 \
                "https://geoip.maxmind.com/geoip/v2.1/city/${ip}" 2>/dev/null || true)
        fi
        if [[ -n "$resp" ]] && echo "$resp" | jq -e '.country != null or .traits != null' >/dev/null 2>&1; then
            printf '%s' "$resp" > "${workdir}/db_maxmind.json"
        fi
    fi
}

# ==============================================================================
# 独立自研核心检测引擎：Phase 2 AI 与流媒体并行探测
# ==============================================================================

is_openai_blocked_cc() {
    case "$1" in
        CN|HK|MO|RU|BY|KP|IR|SY|CU|AF|VE) return 0 ;;
        *) return 1 ;;
    esac
}

is_claude_blocked_cc() {
    case "$1" in
        CN|HK|MO|RU|BY|KP|IR|SY|CU) return 0 ;;
        *) return 1 ;;
    esac
}

probe_media_chatgpt() {
    local stack="$1" out="$2"
    local trace cc api_code web_code status="failed"
    trace=$(curl_exec_stack "$stack" -fsL --connect-timeout 5 --max-time 10 -A "$UA_CHROME" "https://chatgpt.com/cdn-cgi/trace" 2>/dev/null || true)
    cc=$(echo "$trace" | awk -F= '/^loc=/{print $2; exit}' | tr -d '[:space:]')
    api_code=$(curl_exec_stack "$stack" -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://api.openai.com/v1/models" 2>/dev/null || echo "000")
    web_code=$(curl_exec_stack "$stack" -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 -A "$UA_CHROME" "https://ios.chat.openai.com/" 2>/dev/null || echo "000")

    if [[ -n "$cc" ]] && is_openai_blocked_cc "$cc"; then
        status="blocked"
    elif [[ "$api_code" == "401" || "$api_code" == "200" ]]; then
        if [[ "$web_code" == "403" ]]; then
            status="api_only"
        else
            status="yes"
        fi
    elif [[ "$api_code" == "403" || "$api_code" == "451" ]]; then
        status="blocked"
    else
        status="failed"
    fi
    printf '%s|%s\n' "$status" "${cc:-N/A}" > "$out"
}

probe_media_claude() {
    local stack="$1" out="$2"
    local trace cc api_code status="failed"
    trace=$(curl_exec_stack "$stack" -fsL --connect-timeout 5 --max-time 10 -A "$UA_CHROME" "https://claude.ai/cdn-cgi/trace" 2>/dev/null || true)
    cc=$(echo "$trace" | awk -F= '/^loc=/{print $2; exit}' | tr -d '[:space:]')
    api_code=$(curl_exec_stack "$stack" -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "https://api.anthropic.com/v1/messages" 2>/dev/null || echo "000")

    if [[ -n "$cc" ]] && is_claude_blocked_cc "$cc"; then
        status="blocked"
    elif [[ "$api_code" == "401" || "$api_code" == "405" || "$api_code" == "400" || "$api_code" == "200" ]]; then
        status="yes"
    elif [[ "$api_code" == "403" || "$api_code" == "451" ]]; then
        status="blocked"
    else
        status="failed"
    fi
    printf '%s|%s\n' "$status" "${cc:-N/A}" > "$out"
}

probe_media_gemini() {
    local stack="$1" out="$2"
    local tmp_html="${out}.html" status="failed" cc=""
    if curl_exec_stack "$stack" -fsL --compressed --max-filesize 4194304 --connect-timeout 6 --max-time 12 \
        -A "$UA_CHROME" \
        -H "Accept-Language: en-US,en;q=0.9" \
        -H "Cookie: SOCS=CAESHAgBEhIaAB" \
        -o "$tmp_html" \
        "https://gemini.google.com" 2>/dev/null && [[ -s "$tmp_html" ]]; then
        cc=$(grep -oE '2,1,200,"[A-Z]{3}"' "$tmp_html" 2>/dev/null | head -n1 | grep -oE '[A-Z]{3}' || true)
        if grep -q '45631641' "$tmp_html" 2>/dev/null; then
            status="yes"
        else
            status="blocked"
        fi
    fi
    rm -f "$tmp_html" 2>/dev/null || true
    printf '%s|%s\n' "$status" "${cc:-N/A}" > "$out"
}

probe_media_netflix() {
    local stack="$1" out="$2"
    local r1 c1 u1 r2 c2 u2 cc="" status="failed"
    r1=$(curl_exec_stack "$stack" -sL -o /dev/null -w "%{http_code}|%{url_effective}" --connect-timeout 6 --max-time 12 -A "$UA_CHROME" "https://www.netflix.com/title/81280792" 2>/dev/null || echo "000|")
    c1="${r1%%|*}"
    u1="${r1#*|}"
    if [[ "$c1" == "200" ]]; then
        status="yes"
        cc=$(echo "$u1" | sed -nE 's/.*netflix\.com\/([a-zA-Z]{2})(-[a-zA-Z]+)?\/.*/\1/p' | tr '[:lower:]' '[:upper:]')
        [[ -z "$cc" ]] && cc="US"
    elif [[ "$c1" == "404" || "$c1" == "403" ]]; then
        r2=$(curl_exec_stack "$stack" -sL -o /dev/null -w "%{http_code}|%{url_effective}" --connect-timeout 6 --max-time 12 -A "$UA_CHROME" "https://www.netflix.com/title/80018499" 2>/dev/null || echo "000|")
        c2="${r2%%|*}"
        u2="${r2#*|}"
        if [[ "$c2" == "200" ]]; then
            status="originals"
            cc=$(echo "$u2" | sed -nE 's/.*netflix\.com\/([a-zA-Z]{2})(-[a-zA-Z]+)?\/.*/\1/p' | tr '[:lower:]' '[:upper:]')
            [[ -z "$cc" ]] && cc="US"
        elif [[ "$c2" == "403" || "$c1" == "403" ]]; then
            status="blocked"
        else
            status="failed"
        fi
    else
        status="failed"
    fi
    printf '%s|%s\n' "$status" "${cc:-N/A}" > "$out"
}

probe_media_disney() {
    local stack="$1" out="$2"
    local hdrs code loc cc="" status="failed"
    hdrs=$(curl_exec_stack "$stack" -sI --connect-timeout 6 --max-time 12 -A "$UA_CHROME" "https://www.disneyplus.com/" 2>/dev/null || true)
    code=$(echo "$hdrs" | awk 'NR==1{print $2}')
    loc=$(echo "$hdrs" | grep -i '^location:' | head -n1 | tr -d '\r')

    if [[ -z "$code" ]]; then
        status="failed"
    elif echo "$loc" | grep -qi "unavailable"; then
        status="blocked"
    elif [[ "$code" == "403" || "$code" == "451" ]]; then
        status="blocked"
    elif [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]; then
        status="yes"
        cc=$(echo "$loc" | sed -nE 's/.*disneyplus\.com\/[a-z]{2}-([a-z]{2}).*/\1/p' | tr '[:lower:]' '[:upper:]')
        [[ -z "$cc" ]] && cc="US"
    fi
    printf '%s|%s\n' "$status" "${cc:-N/A}" > "$out"
}

probe_media_youtube() {
    local stack="$1" out="$2"
    local tmp_html="${out}.html" cc="" status="failed"
    if curl_exec_stack "$stack" -fsL --compressed --max-filesize 4194304 --connect-timeout 6 --max-time 12 -A "$UA_CHROME" -H "Accept-Language: en" -o "$tmp_html" "https://www.youtube.com/premium" 2>/dev/null && [[ -s "$tmp_html" ]]; then
        cc=$(grep -oE '"countryCode":"[A-Z]{2}"' "$tmp_html" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
        if grep -qi "is not available in your country" "$tmp_html" 2>/dev/null; then
            status="no_prem"
        elif [[ -n "$cc" ]] || grep -qi "YouTube Premium" "$tmp_html" 2>/dev/null; then
            status="yes"
            [[ -z "$cc" ]] && cc="US"
        else
            status="blocked"
        fi
    fi
    rm -f "$tmp_html" 2>/dev/null || true
    printf '%s|%s\n' "$status" "${cc:-N/A}" > "$out"
}

probe_media_tiktok() {
    local stack="$1" out="$2"
    if [[ "$stack" == "6" && -z "$ACTIVE_CURL_CFG" ]]; then
        printf 'no_ipv6|N/A\n' > "$out"
        return 0
    fi
    local tmp_html="${out}.html" cc="" status="failed"
    if curl_exec_stack "$stack" -fsL --compressed --max-filesize 4194304 --connect-timeout 6 --max-time 12 -A "$UA_CHROME" -o "$tmp_html" "https://www.tiktok.com/" 2>/dev/null && [[ -s "$tmp_html" ]]; then
        cc=$(grep -oE '"region":"[A-Z]{2}"' "$tmp_html" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
        if [[ -n "$cc" ]]; then
            status="yes"
        else
            status="blocked"
        fi
    fi
    rm -f "$tmp_html" 2>/dev/null || true
    printf '%s|%s\n' "$status" "${cc:-N/A}" > "$out"
}

probe_media_prime() {
    local stack="$1" out="$2"
    if [[ "$stack" == "6" && -z "$ACTIVE_CURL_CFG" ]]; then
        printf 'no_ipv6|N/A\n' > "$out"
        return 0
    fi
    local tmp_html="${out}.html" cc="" status="failed"
    if curl_exec_stack "$stack" -fsL --compressed --max-filesize 4194304 --connect-timeout 6 --max-time 12 -A "$UA_CHROME" -o "$tmp_html" "https://www.primevideo.com/" 2>/dev/null && [[ -s "$tmp_html" ]]; then
        cc=$(grep -oE '"currentTerritory":"[A-Z]{2}"' "$tmp_html" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
        if [[ "$cc" == "CN" ]]; then
            status="blocked"
        elif [[ -n "$cc" ]]; then
            status="yes"
        else
            status="blocked"
        fi
    fi
    rm -f "$tmp_html" 2>/dev/null || true
    printf '%s|%s\n' "$status" "${cc:-N/A}" > "$out"
}

probe_media_reddit() {
    local stack="$1" out="$2"
    local resp code body cc="" status="failed"
    local -a res_opt=()
    if [[ "$stack" == "6" && -z "$ACTIVE_CURL_CFG" ]]; then
        local dual6=""
        if command -v dig >/dev/null 2>&1; then
            dual6=$(dig +short +time=2 +tries=1 AAAA dualstack.reddit.map.fastly.net 2>/dev/null | grep ':' | head -n1 || true)
        fi
        [[ -z "$dual6" ]] && dual6="2a04:4e42:400::396"
        res_opt=("--resolve" "www.reddit.com:443:[${dual6}]")
    fi
    resp=$(curl_exec_stack "$stack" -sL --http2 --compressed --connect-timeout 6 --max-time 12 \
        ${res_opt[@]+"${res_opt[@]}"} \
        -A "$UA_CHROME" \
        -H "Accept: */*" \
        -H "Accept-Language: en-US,en;q=0.9" \
        -H "Referer: https://www.reddit.com/" \
        -H "Origin: https://www.reddit.com" \
        -H 'Sec-CH-UA: "Google Chrome";v="136", "Chromium";v="136", "Not.A/Brand";v="99"' \
        -H 'Sec-CH-UA-Mobile: ?0' \
        -H 'Sec-CH-UA-Platform: "Windows"' \
        -H 'Sec-Fetch-Dest: empty' \
        -H 'Sec-Fetch-Mode: cors' \
        -H 'Sec-Fetch-Site: same-origin' \
        --write-out '\n%{http_code}' \
        "https://www.reddit.com/svc/shreddit/reddit-chat" 2>/dev/null || true)
    code=$(printf '%s' "$resp" | tail -n1 | tr -d '[:space:]')
    body=$(printf '%s' "$resp" | sed '$d')
    case "$code" in
        200)
            status="yes"
            cc=$(grep -oE 'country="[A-Z]{2}"' <<< "$body" 2>/dev/null | head -n1 | cut -d'"' -f2 || true)
            ;;
        403|451)
            status="blocked"
            ;;
        *)
            status="failed"
            ;;
    esac
    printf '%s|%s\n' "$status" "${cc:-N/A}" > "$out"
}

# ==============================================================================
# 独立自研核心检测引擎：Phase 3 邮局 25 端口 & DNSBL 并行扫描
# ==============================================================================

load_dnsbl_list() {
    local script_dir=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
    fi
    if [[ -n "$script_dir" && -r "${script_dir}/dnsbl.list" ]]; then
        grep -vE '^[[:space:]]*(#|$)' "${script_dir}/dnsbl.list"
    else
        printf '%s\n' "${EMBEDDED_DNSBL_LIST[@]}"
    fi
}

is_dnsbl_hit() {
    local z="$1" ans="$2"
    if [[ -n "$ans" && "$ans" =~ ^127\. && "$ans" != 127.255.255.* && "$ans" != "127.0.1.255" ]]; then
        case "$z" in
            hostkarma.junkemailfilter.com)
                # 127.0.0.1 为白名单，仅 127.0.0.2 为黑名单
                [[ "$ans" == "127.0.0.2" ]] && return 0
                return 1
                ;;
            bl.mailspike.net)
                # 127.0.0.15-20 为中立/优质信誉，仅 127.0.0.2 / 10 / 11 / 12 为黑名单
                case "$ans" in
                    127.0.0.2|127.0.0.10|127.0.0.11|127.0.0.12) return 0 ;;
                    *) return 1 ;;
                esac
                ;;
            *)
                return 0
                ;;
        esac
    fi
    return 1
}

# 单进程 HTTP/2 并行 (curl -Z) 或分批限流并发 DNSBL 扫描（极低内存/单 PID 兼容小鸡容器；代理模式下强制走 DoH 防本机 DNS 泄露）
scan_dnsbl() {
    local ip="$1"
    local out_summary="$2"
    local out_hits="$3"
    local rev_ip
    rev_ip=$(echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')

    local dnsbl_dir="${TMP_WORKDIR}/dnsbl_jobs"
    mkdir -p "$dnsbl_dir"
    rm -f "$dnsbl_dir"/* 2>/dev/null || true

    local use_doh=0
    if [[ -n "$ACTIVE_CURL_CFG" && -f "$ACTIVE_CURL_CFG" ]]; then
        use_doh=1
    elif ! command -v dig >/dev/null 2>&1; then
        use_doh=1
    fi

    local -a zones=()
    local z
    while IFS= read -r z; do
        [[ -n "$z" ]] && zones+=("$z")
    done < <(load_dnsbl_list)

    # 非代理且本机有 dig 时附带 Spamhaus ZEN（自动过滤 127.255.255.* 公共解析器提示码）
    if [[ $use_doh -eq 0 ]]; then
        zones=("zen.spamhaus.org" "${zones[@]}")
    fi

    local max_jobs
    max_jobs=$(detect_max_jobs)
    local total=0 clean=0 hits=0
    : > "$out_hits"

    if [[ $use_doh -eq 1 ]] && curl_supports_parallel; then
        # 单进程 curl -Z 多路复用 DoH 查询：仅占 1 个 PID 与 ~6MB 内存，彻底避免容器 fork 耗尽或 OOM
        # 注意：curl config 的 next 会重置 proxy/interface，因此必须在每个块内重复写入代理/网卡配置，杜绝直连泄露
        local doh_cfg="${dnsbl_dir}/doh.cfg"
        local old_umask
        old_umask=$(umask)
        umask 077
        : > "$doh_cfg"
        chmod 600 "$doh_cfg" 2>/dev/null || true
        umask "$old_umask"

        local proxy_cfg_line=""
        if [[ -n "$ACTIVE_CURL_CFG" && -f "$ACTIVE_CURL_CFG" ]]; then
            proxy_cfg_line=$(cat "$ACTIVE_CURL_CFG")
        fi

        local idx=0
        for z in "${zones[@]}"; do
            idx=$((idx + 1))
            (( idx > 1 )) && printf 'next\n' >> "$doh_cfg"
            {
                printf 'silent\n'
                printf 'location\n'
                printf 'connect-timeout = 3\n'
                printf 'max-time = 5\n'
                printf 'header = "Accept: application/dns-json"\n'
                if [[ -n "$proxy_cfg_line" ]]; then
                    printf '%s\n' "$proxy_cfg_line"
                elif [[ -n "$ACTIVE_IFACE" ]]; then
                    printf 'interface = "%s"\n' "$ACTIVE_IFACE"
                    if is_ipv6_literal "$ACTIVE_IFACE"; then
                        printf 'ipv6\n'
                    elif is_ipv4_literal "$ACTIVE_IFACE"; then
                        printf 'ipv4\n'
                    fi
                fi
                printf 'url = "https://dns.google/resolve?name=%s.%s&type=A"\n' "$rev_ip" "$z"
                printf 'output = "%s/%d.json"\n' "$dnsbl_dir" "$idx"
            } >> "$doh_cfg"
        done

        local pmax="$max_jobs"
        (( pmax < 2 )) && pmax=2
        (( pmax > 4 )) && pmax=4
        curl -Z --parallel-max "$pmax" -K "$doh_cfg" 2>/dev/null || true
        rm -f "$doh_cfg" 2>/dev/null || true

        idx=0
        local ans=""
        for z in "${zones[@]}"; do
            idx=$((idx + 1))
            total=$((total + 1))
            ans=""
            if [[ -s "${dnsbl_dir}/${idx}.json" ]]; then
                ans=$(grep -oE '"data":"127\.[0-9]+\.[0-9]+\.[0-9]+"' "${dnsbl_dir}/${idx}.json" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
            fi
            if is_dnsbl_hit "$z" "$ans"; then
                hits=$((hits + 1))
                echo "${z}|${ans}" >> "$out_hits"
            else
                clean=$((clean + 1))
            fi
        done
        rm -f "${dnsbl_dir}"/*.json 2>/dev/null || true
    else
        local idx=0 batch_cnt=0
        for z in "${zones[@]}"; do
            idx=$((idx + 1))
            batch_cnt=$((batch_cnt + 1))
            (
                local ans="" raw_doh=""
                if [[ $use_doh -eq 1 ]]; then
                    raw_doh=$(curl_exec -fsL --connect-timeout 3 --max-time 5 \
                        -H "Accept: application/dns-json" \
                        "https://dns.google/resolve?name=${rev_ip}.${z}&type=A" 2>/dev/null || true)
                    ans=$(grep -oE '"data":"127\.[0-9]+\.[0-9]+\.[0-9]+"' <<< "$raw_doh" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
                else
                    ans=$(dig +short +time=2 +tries=1 "${rev_ip}.${z}" A 2>/dev/null | head -n1 || true)
                fi

                if is_dnsbl_hit "$z" "$ans"; then
                    echo "HIT|${z}|${ans}" > "${dnsbl_dir}/${idx}.res"
                else
                    echo "CLEAN" > "${dnsbl_dir}/${idx}.res"
                fi
            ) &

            if (( batch_cnt >= max_jobs )); then
                wait
                batch_cnt=0
            fi
        done
        wait

        local f line
        for f in "${dnsbl_dir}"/*.res; do
            [[ -f "$f" ]] || continue
            total=$((total + 1))
            line=$(cat "$f")
            if [[ "$line" == HIT\|* ]]; then
                hits=$((hits + 1))
                echo "${line#HIT|}" >> "$out_hits"
            else
                clean=$((clean + 1))
            fi
        done
    fi

    local mode_tag="dig"
    [[ $use_doh -eq 1 ]] && mode_tag="DoH"
    printf '%d|%d|%d|%s\n' "$total" "$clean" "$hits" "$mode_tag" > "$out_summary"
}

# 直接探测单个 SMTP 25 端口（纯 Bash 单 PID 超时看门狗，绝不使用 BusyBox timeout 或 sh -c 管道）
probe_smtp_host() {
    local host="$1"
    local bind_ip="${2:-}"
    local resp=""
    local -a nc_args=()
    [[ -n "$bind_ip" ]] && nc_args+=("-s" "$bind_ip")
    nc_args+=("-w" "2" "$host" "25")

    resp=$(printf 'QUIT\r\n' | run_with_timeout 3 nc "${nc_args[@]}" 2>&1 || true)
    [[ "$resp" == *"220"* ]]
}

# 邮局 25 端口连通性检测（默认跳过主动外连以防触发云商/LXD/NAT 反垃圾邮件 25 端口风控断连；加 --mail 可主动开启）
scan_mail_port25() {
    local ip="$1"
    local out_file="$2"

    if [[ "$TARGET_MODE" == "port" ]]; then
        printf 'proxy_skip|0||\n' > "$out_file"
        return 0
    fi
    if [[ "$MAIL_MODE" == "skip_user" ]]; then
        printf 'user_skip|0||\n' > "$out_file"
        return 0
    fi

    local local_status="blocked"
    if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -qE ':25([[:space:]]|$)'; then
        local_status="occupied"
    elif command -v netstat >/dev/null 2>&1 && netstat -tln 2>/dev/null | grep -qE '[:.]25([[:space:]]|$)'; then
        local_status="occupied"
    fi

    if [[ "$MAIL_MODE" != "enable" ]]; then
        if [[ "$local_status" == "occupied" ]]; then
            printf 'occupied|0||\n' > "$out_file"
        else
            printf 'default_skip|0||\n' > "$out_file"
        fi
        return 0
    fi

    if ! command -v nc >/dev/null 2>&1; then
        printf 'no_nc|0||\n' > "$out_file"
        return 0
    fi

    # 仅当目标 IP 确实配置在本机网卡上时才传 -s（兼容 NAT 内网小鸡）
    local bind_ip=""
    if is_ipv4_literal "$ip"; then
        if (command -v ip >/dev/null 2>&1 && ip addr show 2>/dev/null | grep -qw "$ip") || \
           (command -v ifconfig >/dev/null 2>&1 && ifconfig 2>/dev/null | grep -qw "$ip"); then
            bind_ip="$ip"
        fi
    fi

    if [[ "$local_status" != "occupied" ]]; then
        if probe_smtp_host "smtp.mailgun.org" "$bind_ip"; then
            local_status="available"
        fi
    fi

    # 若本地出站 25 端口已被云商阻断，立即短路返回（避免无意义连发 6 次 25 端口探针拖慢速度或触发风控）
    if [[ "$local_status" == "blocked" ]]; then
        printf 'blocked|0||\n' > "$out_file"
        return 0
    fi

    # 仅当 25 端口放行时，分批探测 6 大主流邮局 MX 连通性
    local mail_dir="${TMP_WORKDIR}/mail_jobs"
    mkdir -p "$mail_dir"
    rm -f "$mail_dir"/* 2>/dev/null || true

    local providers=("Gmail:gmail.com" "Outlook:outlook.com" "Yahoo:yahoo.com" "Apple:me.com" "QQ:qq.com" "163:163.com")
    local entry name dom batch_cnt=0
    if command -v dig >/dev/null 2>&1; then
        for entry in "${providers[@]}"; do
            name="${entry%%:*}"
            dom="${entry#*:}"
            batch_cnt=$((batch_cnt + 1))
            (
                local mx ok=0
                mx=$(dig +short +time=2 +tries=1 MX "$dom" 2>/dev/null | sort -n | head -n1 | awk '{print $2}')
                if [[ -n "$mx" ]] && probe_smtp_host "$mx" "$bind_ip"; then
                    ok=1
                fi
                echo "${name}:${ok}" > "${mail_dir}/${name}.res"
            ) &
            if (( batch_cnt >= 3 )); then
                wait
                batch_cnt=0
            fi
        done
        wait
    fi

    local ok_list="" fail_list="" ok_cnt=0 f line pname pok
    for entry in "${providers[@]}"; do
        name="${entry%%:*}"
        f="${mail_dir}/${name}.res"
        if [[ -f "$f" ]]; then
            line=$(cat "$f")
            pname="${line%%:*}"
            pok="${line#*:}"
            if [[ "$pok" == "1" ]]; then
                ok_cnt=$((ok_cnt + 1))
                ok_list="${ok_list}${ok_list:+,}${pname}"
            else
                fail_list="${fail_list}${fail_list:+,}${pname}"
            fi
        fi
    done

    printf '%s|%d|%s|%s\n' "$local_status" "$ok_cnt" "$ok_list" "$fail_list" > "$out_file"
}

# ==============================================================================
# 渲染辅助函数（经典 72 列视觉风格：三色渐变评分条、色块标签、横向解锁矩阵）
# ==============================================================================

# 经典 42 列三色渐变风险条（绿 0-33% -> 黄 33-66% -> 红 66-100%，分值与风险等级紧随进度条后，总宽 <= 72 列）
render_risk_bar() {
    local score="$1"
    local custom_score_disp="${2:-}"
    local custom_risk_disp="${3:-}"
    local custom_color="${4:-}"
    (( score < 0 )) && score=0
    (( score > 100 )) && score=100

    local risk_color="$C_GREEN" risk_text=""
    if (( score < 20 )); then
        risk_color="$C_GREEN"
        [[ "$LANG_CODE" == "en" ]] && risk_text="VeryLow" || risk_text="极低风险"
    elif (( score < 40 )); then
        risk_color="$C_GREEN"
        [[ "$LANG_CODE" == "en" ]] && risk_text="Low" || risk_text="低风险"
    elif (( score < 65 )); then
        risk_color="$C_YELLOW"
        [[ "$LANG_CODE" == "en" ]] && risk_text="Medium" || risk_text="中风险"
    elif (( score < 85 )); then
        risk_color="$C_RED"
        [[ "$LANG_CODE" == "en" ]] && risk_text="High" || risk_text="高风险"
    else
        risk_color="$C_RED"
        [[ "$LANG_CODE" == "en" ]] && risk_text="VeryHigh" || risk_text="极高风险"
    fi

    [[ -n "$custom_risk_disp" ]] && risk_text="$custom_risk_disp"
    [[ -n "$custom_color" ]] && risk_color="$custom_color"
    local score_disp="${custom_score_disp:-$score}"

    local bar_w=42
    local fill_len=1
    if (( score > 0 )); then
        fill_len=$(( (score * bar_w + 50) / 100 ))
        (( fill_len < 1 )) && fill_len=1
        (( fill_len > bar_w )) && fill_len=$bar_w
    fi

    local left_pad=$(( fill_len - 1 ))
    local filled_str
    filled_str="$(printf '%*s' "$left_pad" '')|"

    local s1="${filled_str:0:14}"
    local s2="${filled_str:14:14}"
    local s3="${filled_str:28:14}"

    local out=""
    [[ -n "$s1" ]] && out+="${BG_GREEN}${C_BLACK}${s1}"
    [[ -n "$s2" ]] && out+="${BG_YELLOW}${C_BLACK}${s2}"
    [[ -n "$s3" ]] && out+="${BG_RED}${C_BLACK}${s3}"
    if [[ "$score_disp" == "-" ]]; then
        out+="${C_RESET} ${risk_color}${C_BOLD}${risk_text}${C_RESET}"
    else
        out+="${C_RESET} ${risk_color}${C_BOLD}${score_disp} ${risk_text}${C_RESET}"
    fi
    printf "%b" "$out"
}

# 10 列定宽色块类型标签（用于「二、IP类型属性」6 列横向矩阵，总宽 10 + 6*10 = 70 <= 72 列，深色字体高对比度，无/未知使用紫色色块）
render_type_cell() {
    local raw="${1:-}"
    # IP2Location 支持 "ISP/MOB" 复合格式，取主类型
    local primary="${raw%%/*}"
    local low
    low=$(echo "$primary" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    if [[ "$LANG_CODE" == "en" ]]; then
        case "$low" in
            isp|residential|"fixed line isp"|lineisp)
                printf "  ${BG_GREEN}${C_BLACK} ISP  ${C_RESET}  " ;;
            mobile|mob|wireless|"mobile isp")
                printf " ${BG_GREEN}${C_BLACK} Mobile ${C_RESET} " ;;
            business|commercial|com)
                printf " ${BG_YELLOW}${C_BLACK}Business${C_RESET} " ;;
            hosting|datacenter|dch|"data center"*)
                printf " ${BG_RED}${C_BLACK}Hosting ${C_RESET} " ;;
            cdn|"content delivery"*)
                printf "  ${BG_RED}${C_BLACK} CDN  ${C_RESET}  " ;;
            vpn)
                printf "  ${BG_RED}${C_BLACK} VPN  ${C_RESET}  " ;;
            socks*|proxy|compromised)
                printf " ${BG_RED}${C_BLACK} Proxy  ${C_RESET} " ;;
            education|edu|university*)
                printf "  ${BG_YELLOW}${C_BLACK} Edu  ${C_RESET}  " ;;
            government|gov)
                printf "  ${BG_YELLOW}${C_BLACK} Gov  ${C_RESET}  " ;;
            banking)
                printf "  ${BG_YELLOW}${C_BLACK} Bank ${C_RESET}  " ;;
            organization|org)
                printf "  ${BG_YELLOW}${C_BLACK} Org  ${C_RESET}  " ;;
            military|mil)
                printf "  ${BG_YELLOW}${C_BLACK} Mil  ${C_RESET}  " ;;
            library|lib)
                printf "  ${BG_YELLOW}${C_BLACK} Lib  ${C_RESET}  " ;;
            spider|ses|"search engine"*)
                printf " ${BG_RED}${C_BLACK} Spider ${C_RESET} " ;;
            reserved|rsv)
                printf "  ${BG_YELLOW}${C_BLACK} Rsrv ${C_RESET}  " ;;
            ""|null|unknown|-)
                printf "  ${BG_PURPLE}${C_BLACK} N/A  ${C_RESET}  " ;;
            *)
                printf " ${BG_YELLOW}${C_BLACK} Other  ${C_RESET} " ;;
        esac
    else
        case "$low" in
            isp|residential|"fixed line isp"|lineisp)
                printf "  ${BG_GREEN}${C_BLACK} 家宽 ${C_RESET}  " ;;
            mobile|mob|wireless|"mobile isp")
                printf "  ${BG_GREEN}${C_BLACK} 移动 ${C_RESET}  " ;;
            business|commercial|com)
                printf "  ${BG_YELLOW}${C_BLACK} 商业 ${C_RESET}  " ;;
            hosting|datacenter|dch|"data center"*)
                printf "  ${BG_RED}${C_BLACK} 机房 ${C_RESET}  " ;;
            cdn|"content delivery"*)
                printf "  ${BG_RED}${C_BLACK} CDN  ${C_RESET}  " ;;
            vpn)
                printf "  ${BG_RED}${C_BLACK} VPN  ${C_RESET}  " ;;
            socks*|proxy|compromised)
                printf "  ${BG_RED}${C_BLACK} 代理 ${C_RESET}  " ;;
            education|edu|university*)
                printf "  ${BG_YELLOW}${C_BLACK} 教育 ${C_RESET}  " ;;
            government|gov)
                printf "  ${BG_YELLOW}${C_BLACK} 政府 ${C_RESET}  " ;;
            banking)
                printf "  ${BG_YELLOW}${C_BLACK} 银行 ${C_RESET}  " ;;
            organization|org)
                printf "  ${BG_YELLOW}${C_BLACK} 组织 ${C_RESET}  " ;;
            military|mil)
                printf "  ${BG_YELLOW}${C_BLACK} 军队 ${C_RESET}  " ;;
            library|lib)
                printf " ${BG_YELLOW}${C_BLACK} 图书馆 ${C_RESET} " ;;
            spider|ses|"search engine"*)
                printf "  ${BG_RED}${C_BLACK} 蜘蛛 ${C_RESET}  " ;;
            reserved|rsv)
                printf "  ${BG_YELLOW}${C_BLACK} 保留 ${C_RESET}  " ;;
            ""|null|unknown|-)
                printf "  ${BG_PURPLE}${C_BLACK}  无  ${C_RESET}  " ;;
            *)
                printf "  ${BG_YELLOW}${C_BLACK} 其他 ${C_RESET}  " ;;
        esac
    fi
}

# 8 列定宽风险因子单元格（8 + 8*8 = 72 列精确对齐，[US] / 是 / 否 / 无）
render_factor_cc() {
    local cc="$1"
    if [[ -n "$cc" && "$cc" != "N/A" && "$cc" != "null" && ${#cc} -eq 2 ]]; then
        printf "  ${C_GREEN}[%s]${C_RESET}  " "$cc"
    else
        if [[ "$LANG_CODE" == "en" ]]; then
            printf "  ${C_PURPLE}N/A${C_RESET}   "
        else
            printf "   ${C_PURPLE}无${C_RESET}   "
        fi
    fi
}

render_factor_bool() {
    local val="$1"
    case "$val" in
        true|yes|1)
            if [[ "$LANG_CODE" == "en" ]]; then
                printf "  ${C_RED}${C_BOLD}Yes${C_RESET}   "
            else
                printf "   ${C_RED}${C_BOLD}是${C_RESET}   "
            fi
            ;;
        false|no|0)
            if [[ "$LANG_CODE" == "en" ]]; then
                printf "   ${C_GREEN}${C_BOLD}No${C_RESET}   "
            else
                printf "   ${C_GREEN}${C_BOLD}否${C_RESET}   "
            fi
            ;;
        *)
            if [[ "$LANG_CODE" == "en" ]]; then
                printf "  ${C_PURPLE}N/A${C_RESET}   "
            else
                printf "   ${C_PURPLE}无${C_RESET}   "
            fi
            ;;
    esac
}

# 8 列定宽流媒体/AI 色块状态标签（横向矩阵，深色字体高对比度）
render_media_badge_8() {
    local status="$1"
    if [[ "$LANG_CODE" == "en" ]]; then
        case "$status" in
            yes)       printf " ${BG_GREEN}${C_BLACK} Yes  ${C_RESET} " ;;
            originals) printf "${BG_YELLOW}${C_BLACK} Orig.  ${C_RESET}" ;;
            api_only)  printf "${BG_YELLOW}${C_BLACK} APIOnl ${C_RESET}" ;;
            no_prem)   printf "${BG_RED}${C_BLACK} NoPrem ${C_RESET}" ;;
            blocked)   printf "${BG_RED}${C_BLACK} Block  ${C_RESET}" ;;
            no_ipv6)   printf " ${BG_PURPLE}${C_BLACK} NoV6 ${C_RESET} " ;;
            *)         printf " ${BG_RED}${C_BLACK} Fail ${C_RESET} " ;;
        esac
    else
        case "$status" in
            yes)       printf " ${BG_GREEN}${C_BLACK} 解锁 ${C_RESET} " ;;
            originals) printf "${BG_YELLOW}${C_BLACK} 仅自制 ${C_RESET}" ;;
            api_only)  printf "${BG_YELLOW}${C_BLACK} 仅API  ${C_RESET}" ;;
            no_prem)   printf "${BG_RED}${C_BLACK} 禁会员 ${C_RESET}" ;;
            blocked)   printf " ${BG_RED}${C_BLACK} 屏蔽 ${C_RESET} " ;;
            no_ipv6)   printf " ${BG_PURPLE}${C_BLACK} 无V6 ${C_RESET} " ;;
            *)         printf " ${BG_RED}${C_BLACK} 失败 ${C_RESET} " ;;
        esac
    fi
}

# 8 列定宽流媒体/AI 地区行
render_media_region_8() {
    local status="$1"
    local cc="$2"
    if [[ "$status" == "failed" || "$status" == "no_ipv6" || -z "$cc" || "$cc" == "N/A" ]]; then
        printf "        "
    elif [[ ${#cc} -eq 2 ]]; then
        printf "  ${C_GREEN}[%s]${C_RESET}  " "$cc"
    elif [[ ${#cc} -eq 3 ]]; then
        printf " ${C_GREEN}[%s]${C_RESET}  " "$cc"
    else
        printf "        "
    fi
}

# 经典红/绿邮局连通性块标签（+Gmail / -Outlook）
render_mail_badges() {
    local ok_csv="$1"
    local fail_csv="$2"
    local providers=("Gmail" "Outlook" "Yahoo" "Apple" "QQ" "163")
    local p out=""
    for p in "${providers[@]}"; do
        if [[ ",${ok_csv}," == *",${p},"* ]]; then
            out+="${C_GREEN}+${C_RESET}${BG_GREEN}${C_BLACK}${p}${C_RESET} "
        elif [[ ",${fail_csv}," == *",${p},"* ]]; then
            out+="${C_RED}-${C_RESET}${BG_RED}${C_BLACK}${p}${C_RESET} "
        fi
    done
    printf "%b" "$out"
}

# 72 列居中标题输出辅助（自动计算中英文显示宽度）
print_centered_72() {
    local plain_text="$1"
    local formatted_text="$2"
    local vis_len
    vis_len=$(printf '%s' "$plain_text" | LC_ALL=C awk '{
        w = 0
        n = length($0)
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (c ~ /[\000-\177]/) w += 1
            else { w += 2; i += 2 }
        }
        print w
    }' 2>/dev/null || echo "${#plain_text}")
    local pad=$(( (72 - vis_len) / 2 ))
    (( pad < 0 )) && pad=0
    printf '%*s%b\n' "$pad" '' "$formatted_text"
}

# ==============================================================================
# 单 IP 完整体检流程（3 阶段并发执行）
# ==============================================================================

run_single_ip_check() {
    local ip="$1"
    local stack="$2"
    local out_path="$3"
    local display_ip
    display_ip=$(format_ip_display "$ip")

    local run_dir="${TMP_WORKDIR}/run_${stack}_${RANDOM}"
    mkdir -p "$run_dir"

    local max_jobs batch_cnt=0
    max_jobs=$(detect_max_jobs)

    # ---------------- Phase 1: 按容器安全并发上限分批查询 9 大独立免费 IP 情报库 + 可选扩展库 ----------------
    echo -ne "${C_CYAN}[${display_ip}]${C_RESET} ${C_DIM}(1/3) 正在并发查询多源 IP 情报与风控数据库 (9+ 权威源)...${C_RESET}" >&2
    local p1_task
    for p1_task in ipinfo ipregistry ip2loc scam proxycheck ipquery ipapi dbip ipguide sfs byok; do
        case "$p1_task" in
            ipinfo)     fetch_db_json "https://ipinfo.io/widget/demo/${ip}" "$stack" "${run_dir}/db_ipinfo.json" & ;;
            ipregistry) fetch_ipregistry_data "$ip" "$stack" "${run_dir}/db_ipregistry.json" & ;;
            ip2loc)     fetch_ip2location_data "$ip" "$stack" "${run_dir}/db_ip2loc.json" & ;;
            scam)       fetch_scamalytics_data "$ip" "${run_dir}/db_scam.json" & ;;
            proxycheck) fetch_db_json "https://proxycheck.io/v2/${ip}?vpn=1&asn=1&risk=1" "$stack" "${run_dir}/db_proxycheck.json" & ;;
            ipquery)    fetch_db_json "https://api.ipquery.io/${ip}" "$stack" "${run_dir}/db_ipquery.json" & ;;
            ipapi)      fetch_db_json "http://ip-api.com/json/${ip}?fields=status,continent,continentCode,country,countryCode,regionName,city,zip,lat,lon,timezone,isp,org,as,reverse,mobile,proxy,hosting" "$stack" "${run_dir}/db_ipapi.json" & ;;
            dbip)       fetch_dbip_data "$ip" "$stack" "${run_dir}/db_dbip.json" & ;;
            ipguide)    fetch_db_json "https://ip.guide/${ip}" "$stack" "${run_dir}/db_ipguide.json" & ;;
            sfs)        fetch_db_json "https://api.stopforumspam.org/api?ip=${ip}&json" "$stack" "${run_dir}/db_sfs.json" & ;;
            byok)       fetch_optional_byok "$ip" "$run_dir" & ;;
        esac
        batch_cnt=$((batch_cnt + 1))
        if (( batch_cnt >= max_jobs )); then
            wait
            batch_cnt=0
        fi
    done
    wait
    echo -ne "\r\033[2K" >&2

    # ---------------- Phase 2: 按容器安全并发上限分批检测 9 大 AI 与流媒体平台 ----------------
    if [[ "$SKIP_MEDIA" -eq 0 ]]; then
        echo -ne "${C_CYAN}[${display_ip}]${C_RESET} ${C_DIM}(2/3) 正在并发检测 AI (ChatGPT/Claude/Gemini) 与流媒体解锁...${C_RESET}" >&2
        batch_cnt=0
        local p2_task
        for p2_task in chatgpt claude gemini netflix disney youtube tiktok prime reddit; do
            case "$p2_task" in
                chatgpt) probe_media_chatgpt "$stack" "${run_dir}/m_chatgpt.txt" & ;;
                claude)  probe_media_claude "$stack" "${run_dir}/m_claude.txt" & ;;
                gemini)  probe_media_gemini "$stack" "${run_dir}/m_gemini.txt" & ;;
                netflix) probe_media_netflix "$stack" "${run_dir}/m_netflix.txt" & ;;
                disney)  probe_media_disney "$stack" "${run_dir}/m_disney.txt" & ;;
                youtube) probe_media_youtube "$stack" "${run_dir}/m_youtube.txt" & ;;
                tiktok)  probe_media_tiktok "$stack" "${run_dir}/m_tiktok.txt" & ;;
                prime)   probe_media_prime "$stack" "${run_dir}/m_prime.txt" & ;;
                reddit)  probe_media_reddit "$stack" "${run_dir}/m_reddit.txt" & ;;
            esac
            batch_cnt=$((batch_cnt + 1))
            if (( batch_cnt >= max_jobs )); then
                wait
                batch_cnt=0
            fi
        done
        wait
        echo -ne "\r\033[2K" >&2
    fi

    # ---------------- Phase 3: 单进程 DoH / 限流 DNSBL 扫描与可选 25 端口检测 ----------------
    if [[ "$MAIL_MODE" == "enable" ]]; then
        echo -ne "${C_CYAN}[${display_ip}]${C_RESET} ${C_DIM}(3/3) 正在扫描 DNSBL 黑名单与邮局 25 端口...${C_RESET}" >&2
    else
        echo -ne "${C_CYAN}[${display_ip}]${C_RESET} ${C_DIM}(3/3) 正在扫描 DNSBL 黑名单...${C_RESET}" >&2
    fi
    if [[ "$stack" == "4" ]]; then
        scan_dnsbl "$ip" "${run_dir}/dnsbl_summary.txt" "${run_dir}/dnsbl_hits.txt"
    fi
    scan_mail_port25 "$ip" "${run_dir}/mail_summary.txt"
    echo -ne "\r\033[2K" >&2

    # ---------------- 聚合解析各数据源字段 ----------------
    local f_ipinfo="${run_dir}/db_ipinfo.json"
    local f_ipreg="${run_dir}/db_ipregistry.json"
    local f_ip2loc="${run_dir}/db_ip2loc.json"
    local f_scam="${run_dir}/db_scam.json"
    local f_pcheck="${run_dir}/db_proxycheck.json"
    local f_ipquery="${run_dir}/db_ipquery.json"
    local f_ipapi="${run_dir}/db_ipapi.json"
    local f_dbip="${run_dir}/db_dbip.json"
    local f_ipguide="${run_dir}/db_ipguide.json"
    local f_sfs="${run_dir}/db_sfs.json"
    local f_ipapi_is="${run_dir}/db_ipapi_is.json"
    local f_abuse="${run_dir}/db_abuseipdb.json"
    local f_ipdata="${run_dir}/db_ipdata.json"
    local f_ipqs="${run_dir}/db_ipqs.json"
    local f_maxmind="${run_dir}/db_maxmind.json"

    local has_maxmind=0
    [[ -f "$f_maxmind" ]] && has_maxmind=1

    # 基础信息（MaxMind 优先 + 9 大免费源智能融合回退，全面覆盖 ASN/组织/运营商/CIDR/RIR/rDNS/DMS坐标/地图/邮编/洲际/注册地/原生判定）
    local asn="" org="" isp="" cidr="" rir="" rdns=""
    local country_code="" country_name="" continent_code="" region_name="" city_name="" postal_code="" timezone="" reg_country=""
    local lat="" lon="" dms="" map_url="" is_anycast="false"

    if [[ $has_maxmind -eq 1 ]]; then
        asn=$(jq -r '.traits.autonomous_system_number // empty' "$f_maxmind" 2>/dev/null | sed 's/^\([0-9]\)/AS\1/')
        org=$(jq -r '.traits.autonomous_system_organization // .traits.organization // empty' "$f_maxmind" 2>/dev/null)
        isp=$(jq -r '.traits.isp // empty' "$f_maxmind" 2>/dev/null)
        cidr=$(jq -r '.traits.network // empty' "$f_maxmind" 2>/dev/null)
        country_code=$(jq -r '.country.iso_code // empty' "$f_maxmind" 2>/dev/null)
        country_name=$(jq -r '.country.names.en // empty' "$f_maxmind" 2>/dev/null)
        continent_code=$(jq -r '.continent.code // empty' "$f_maxmind" 2>/dev/null)
        reg_country=$(jq -r '.registered_country.iso_code // empty' "$f_maxmind" 2>/dev/null)
        region_name=$(jq -r '.subdivisions[0].names.en // empty' "$f_maxmind" 2>/dev/null)
        city_name=$(jq -r '.city.names.en // empty' "$f_maxmind" 2>/dev/null)
        postal_code=$(jq -r '.postal.code // empty' "$f_maxmind" 2>/dev/null)
        timezone=$(jq -r '.location.time_zone // empty' "$f_maxmind" 2>/dev/null)
        lat=$(jq -r '.location.latitude // empty' "$f_maxmind" 2>/dev/null)
        lon=$(jq -r '.location.longitude // empty' "$f_maxmind" 2>/dev/null)
    fi

    [[ -z "$asn" ]] && asn=$(jq -r '.data.asn.asn // empty' "$f_ipinfo" 2>/dev/null)
    [[ -z "$asn" ]] && asn=$(jq -r '.connection.asn // empty' "$f_ipreg" 2>/dev/null | sed 's/^\([0-9]\)/AS\1/')
    [[ -z "$asn" ]] && asn=$(jq -r '.asn // empty' "$f_ip2loc" 2>/dev/null | sed 's/^\([0-9]\)/AS\1/')
    [[ -z "$asn" ]] && asn=$(jq -r '.isp.asn // empty' "$f_ipquery" 2>/dev/null)
    [[ -z "$asn" ]] && asn=$(jq -r --arg ip "$ip" '.[$ip].asn // empty' "$f_pcheck" 2>/dev/null)
    [[ -z "$asn" ]] && asn=$(jq -r '.network.autonomous_system.asn // empty' "$f_ipguide" 2>/dev/null | sed 's/^\([0-9]\)/AS\1/')

    [[ -z "$org" ]] && org=$(jq -r '.data.asn.name // .data.company.name // empty' "$f_ipinfo" 2>/dev/null)
    [[ -z "$org" ]] && org=$(jq -r '.connection.organization // .company.name // empty' "$f_ipreg" 2>/dev/null)
    [[ -z "$org" ]] && org=$(jq -r '.as // .isp // empty' "$f_ip2loc" 2>/dev/null)
    [[ -z "$org" ]] && org=$(jq -r '.isp.org // .isp.isp // empty' "$f_ipquery" 2>/dev/null)
    [[ -z "$org" ]] && org=$(jq -r --arg ip "$ip" '.[$ip].organisation // .[$ip].provider // empty' "$f_pcheck" 2>/dev/null)
    [[ -z "$org" ]] && org=$(jq -r '.org // .isp // empty' "$f_ipapi" 2>/dev/null)
    [[ -z "$org" ]] && org=$(jq -r '.network.autonomous_system.organization // .network.autonomous_system.name // empty' "$f_ipguide" 2>/dev/null)

    [[ -z "$isp" ]] && isp=$(jq -r '.isp // empty' "$f_ip2loc" 2>/dev/null)
    [[ -z "$isp" ]] && isp=$(jq -r '.isp.isp // empty' "$f_ipquery" 2>/dev/null)
    [[ -z "$isp" ]] && isp=$(jq -r --arg ip "$ip" '.[$ip].provider // empty' "$f_pcheck" 2>/dev/null)
    [[ -z "$isp" ]] && isp=$(jq -r '.isp // empty' "$f_ipapi" 2>/dev/null)
    [[ -z "$isp" || "$isp" == "-" ]] && isp="$org"

    [[ -z "$cidr" ]] && cidr=$(jq -r '.data.asn.route // empty' "$f_ipinfo" 2>/dev/null)
    [[ -z "$cidr" ]] && cidr=$(jq -r '.as_info.as_cidr // empty' "$f_ip2loc" 2>/dev/null)
    [[ -z "$cidr" ]] && cidr=$(jq -r '.network.cidr // empty' "$f_ipguide" 2>/dev/null)
    [[ -z "$cidr" ]] && cidr=$(jq -r --arg ip "$ip" '.[$ip].range // empty' "$f_pcheck" 2>/dev/null)
    [[ -z "$cidr" && -f "$f_ipapi_is" ]] && cidr=$(jq -r '.asn.route // empty' "$f_ipapi_is" 2>/dev/null)
    [[ "$cidr" == "-" ]] && cidr=""

    rir=$(jq -r '.network.autonomous_system.rir // empty' "$f_ipguide" 2>/dev/null)
    [[ -z "$rir" && -f "$f_ipapi_is" ]] && rir=$(jq -r '.rir // .asn.rir // empty' "$f_ipapi_is" 2>/dev/null)

    rdns=$(jq -r '.data.hostname // empty' "$f_ipinfo" 2>/dev/null)
    [[ -z "$rdns" ]] && rdns=$(jq -r '.hostname // empty' "$f_ipreg" 2>/dev/null)
    [[ -z "$rdns" ]] && rdns=$(jq -r '.reverse // empty' "$f_ipapi" 2>/dev/null)
    [[ -z "$rdns" ]] && rdns=$(jq -r --arg ip "$ip" '.[$ip].hostname // empty' "$f_pcheck" 2>/dev/null)
    [[ -z "$rdns" ]] && rdns=$(jq -r '.hostname // empty' "$f_scam" 2>/dev/null)
    if [[ -z "$rdns" && -z "$ACTIVE_CURL_CFG" ]] && command -v dig >/dev/null 2>&1; then
        rdns=$(dig +short +time=2 +tries=1 -x "$ip" 2>/dev/null | head -n1 | sed 's/\.$//' || true)
    fi
    # 过滤掉伪造/纯 IP/非法格式的 PTR 返回值，并在隐私模式下遮蔽嵌入主机名中的 IP 段
    if [[ -n "$rdns" ]]; then
        if is_valid_ip_literal "$rdns" || [[ ! "$rdns" =~ ^[a-zA-Z0-9._-]+$ ]] || [[ "$rdns" != *.* ]] || [[ ! "$rdns" =~ [a-zA-Z] ]]; then
            rdns=""
        else
            rdns=$(mask_rdns_for_privacy "$rdns" "$ip")
        fi
    fi

    local cidr_disp=""
    [[ -n "$cidr" ]] && cidr_disp=$(format_ip_display "$cidr")

    [[ -z "$country_code" ]] && country_code=$(jq -r '.data.country // empty' "$f_ipinfo" 2>/dev/null)
    [[ -z "$country_code" ]] && country_code=$(jq -r '.location.country.code // empty' "$f_ipreg" 2>/dev/null)
    [[ -z "$country_code" ]] && country_code=$(jq -r '.country_code // empty' "$f_ip2loc" 2>/dev/null)
    [[ -z "$country_code" ]] && country_code=$(jq -r '.location.country_code // empty' "$f_ipquery" 2>/dev/null)
    [[ -z "$country_code" ]] && country_code=$(jq -r --arg ip "$ip" '.[$ip].isocode // empty' "$f_pcheck" 2>/dev/null)
    [[ -z "$country_code" ]] && country_code=$(jq -r '.countryCode // empty' "$f_ipapi" 2>/dev/null)
    [[ -z "$country_code" ]] && country_code=$(jq -r '.countryCode // empty' "$f_dbip" 2>/dev/null)
    [[ "$country_code" == "-" ]] && country_code=""

    [[ -z "$country_name" ]] && country_name=$(jq -r '.location.country.name // empty' "$f_ipreg" 2>/dev/null)
    [[ -z "$country_name" ]] && country_name=$(jq -r '.location.country // empty' "$f_ipquery" 2>/dev/null)
    [[ -z "$country_name" ]] && country_name=$(jq -r --arg ip "$ip" '.[$ip].country // empty' "$f_pcheck" 2>/dev/null)
    [[ -z "$country_name" ]] && country_name=$(jq -r '.country // empty' "$f_ipapi" 2>/dev/null)
    [[ -z "$country_name" ]] && country_name=$(jq -r '.country_name // empty' "$f_ip2loc" 2>/dev/null)
    [[ -z "$country_name" ]] && country_name=$(jq -r '.countryName // empty' "$f_dbip" 2>/dev/null)

    [[ -z "$continent_code" ]] && continent_code=$(jq -r '.continent.code // empty' "$f_ip2loc" 2>/dev/null)
    [[ -z "$continent_code" ]] && continent_code=$(jq -r '.location.continent.code // empty' "$f_ipreg" 2>/dev/null)
    [[ -z "$continent_code" ]] && continent_code=$(jq -r --arg ip "$ip" '.[$ip].continentcode // empty' "$f_pcheck" 2>/dev/null)
    [[ -z "$continent_code" ]] && continent_code=$(jq -r '.continentCode // empty' "$f_ipapi" 2>/dev/null)
    [[ -z "$continent_code" ]] && continent_code=$(jq -r '.continentCode // empty' "$f_dbip" 2>/dev/null)
    [[ -z "$continent_code" && -n "$country_code" ]] && continent_code=$(lookup_continent_from_cc "$country_code")

    [[ -z "$region_name" ]] && region_name=$(jq -r '.data.region // empty' "$f_ipinfo" 2>/dev/null)
    [[ -z "$region_name" ]] && region_name=$(jq -r '.location.region.name // empty' "$f_ipreg" 2>/dev/null)
    [[ -z "$region_name" ]] && region_name=$(jq -r '.region_name // empty' "$f_ip2loc" 2>/dev/null)
    [[ -z "$region_name" ]] && region_name=$(jq -r '.location.state // empty' "$f_ipquery" 2>/dev/null)
    [[ -z "$region_name" ]] && region_name=$(jq -r '.regionName // empty' "$f_ipapi" 2>/dev/null)
    [[ -z "$region_name" ]] && region_name=$(jq -r '.stateProv // empty' "$f_dbip" 2>/dev/null)
    [[ -z "$region_name" ]] && region_name=$(jq -r '.region // empty' "$f_scam" 2>/dev/null)
    [[ "$region_name" == "-" ]] && region_name=""

    [[ -z "$city_name" ]] && city_name=$(jq -r '.data.city // empty' "$f_ipinfo" 2>/dev/null)
    [[ -z "$city_name" ]] && city_name=$(jq -r '.location.city // empty' "$f_ipreg" 2>/dev/null)
    [[ -z "$city_name" ]] && city_name=$(jq -r '.city_name // empty' "$f_ip2loc" 2>/dev/null)
    [[ -z "$city_name" ]] && city_name=$(jq -r '.location.city // empty' "$f_ipquery" 2>/dev/null)
    [[ -z "$city_name" ]] && city_name=$(jq -r '.city // empty' "$f_ipapi" 2>/dev/null)
    [[ -z "$city_name" ]] && city_name=$(jq -r '.city // empty' "$f_dbip" 2>/dev/null)
    [[ -z "$city_name" ]] && city_name=$(jq -r '.city // empty' "$f_scam" 2>/dev/null)
    [[ "$city_name" == "-" ]] && city_name=""

    [[ -z "$postal_code" ]] && postal_code=$(jq -r '.data.postal // empty' "$f_ipinfo" 2>/dev/null)
    [[ -z "$postal_code" ]] && postal_code=$(jq -r '.zip_code // empty' "$f_ip2loc" 2>/dev/null)
    [[ -z "$postal_code" ]] && postal_code=$(jq -r '.location.postal // empty' "$f_ipreg" 2>/dev/null)
    [[ -z "$postal_code" ]] && postal_code=$(jq -r --arg ip "$ip" '.[$ip].postcode // empty' "$f_pcheck" 2>/dev/null)
    [[ -z "$postal_code" ]] && postal_code=$(jq -r '.zip // empty' "$f_ipapi" 2>/dev/null)
    [[ -z "$postal_code" ]] && postal_code=$(jq -r '.location.zipcode // empty' "$f_ipquery" 2>/dev/null)
    [[ -z "$postal_code" ]] && postal_code=$(jq -r '.postal // empty' "$f_scam" 2>/dev/null)
    [[ "$postal_code" == "-" || "$postal_code" == "null" ]] && postal_code=""

    [[ -z "$timezone" ]] && timezone=$(jq -r '.data.timezone // empty' "$f_ipinfo" 2>/dev/null)
    [[ -z "$timezone" ]] && timezone=$(jq -r '.time_zone.id // empty' "$f_ipreg" 2>/dev/null)
    [[ -z "$timezone" ]] && timezone=$(jq -r '.time_zone_info.olson // empty' "$f_ip2loc" 2>/dev/null)
    [[ -z "$timezone" ]] && timezone=$(jq -r '.location.timezone // empty' "$f_ipquery" 2>/dev/null)
    [[ -z "$timezone" ]] && timezone=$(jq -r '.timezone // empty' "$f_ipapi" 2>/dev/null)

    # 坐标与地图链接（多源回退，使用纯 awk 转 DMS 度分秒）
    if [[ -z "$lat" || -z "$lon" ]]; then
        local ii_loc
        ii_loc=$(jq -r '.data.loc // empty' "$f_ipinfo" 2>/dev/null)
        if [[ "$ii_loc" == *,* ]]; then
            lat="${ii_loc%%,*}"
            lon="${ii_loc#*,}"
        fi
    fi
    if [[ -z "$lat" || -z "$lon" ]]; then
        lat=$(jq -r '.latitude // empty' "$f_ip2loc" 2>/dev/null)
        lon=$(jq -r '.longitude // empty' "$f_ip2loc" 2>/dev/null)
    fi
    if [[ -z "$lat" || -z "$lon" ]]; then
        lat=$(jq -r '.location.latitude // empty' "$f_ipreg" 2>/dev/null)
        lon=$(jq -r '.location.longitude // empty' "$f_ipreg" 2>/dev/null)
    fi
    if [[ -z "$lat" || -z "$lon" ]]; then
        lat=$(jq -r '.location.latitude // empty' "$f_ipquery" 2>/dev/null)
        lon=$(jq -r '.location.longitude // empty' "$f_ipquery" 2>/dev/null)
    fi
    if [[ -z "$lat" || -z "$lon" ]]; then
        lat=$(jq -r '.lat // empty' "$f_ipapi" 2>/dev/null)
        lon=$(jq -r '.lon // empty' "$f_ipapi" 2>/dev/null)
    fi
    if [[ -z "$lat" || -z "$lon" ]]; then
        lat=$(jq -r '.lat // empty' "$f_scam" 2>/dev/null)
        lon=$(jq -r '.lon // empty' "$f_scam" 2>/dev/null)
    fi
    if [[ -z "$lat" || -z "$lon" ]]; then
        lat=$(jq -r '.location.latitude // empty' "$f_ipguide" 2>/dev/null)
        lon=$(jq -r '.location.longitude // empty' "$f_ipguide" 2>/dev/null)
    fi
    if [[ -n "$lat" && -n "$lon" ]]; then
        dms=$(format_dms "$lat" "$lon")
        map_url=$(format_map_url "$lat" "$lon")
    fi

    # 注册地多源回退（MaxMind -> IPinfo abuse -> ipapi.is ASN -> ip.guide RIR/ASN）
    [[ -z "$reg_country" ]] && reg_country=$(jq -r '.data.abuse.country // empty' "$f_ipinfo" 2>/dev/null)
    [[ -z "$reg_country" && -f "$f_ipapi_is" ]] && reg_country=$(jq -r '.asn.country // empty' "$f_ipapi_is" 2>/dev/null | tr '[:lower:]' '[:upper:]')
    [[ -z "$reg_country" ]] && reg_country=$(jq -r '.network.autonomous_system.country // empty' "$f_ipguide" 2>/dev/null | tr '[:lower:]' '[:upper:]')
    [[ "$reg_country" == "-" ]] && reg_country=""

    if [[ "$(jq -r '.data.is_anycast // false' "$f_ipinfo" 2>/dev/null)" == "true" ]] || \
       [[ "$(jq -r '.address_type // ""' "$f_ip2loc" 2>/dev/null)" == "Anycast" ]] || \
       { [[ -f "$f_ipapi_is" ]] && [[ "$(jq -r '.is_anycast // false' "$f_ipapi_is" 2>/dev/null)" == "true" ]]; }; then
        is_anycast="true"
    fi

    # 类型字段（6 大免Key直连库 + 可选 ipapi.is & AbuseIPDB 扩展库）
    local t_ipinfo_use t_ipinfo_com t_ipreg_use t_ipreg_com t_ip2loc_use t_ip2loc_com t_pcheck
    local t_ipapi_is_use="" t_ipapi_is_com="" t_abuse_use=""
    t_ipinfo_use=$(jq -r '.data.asn.type // ""' "$f_ipinfo" 2>/dev/null)
    t_ipinfo_com=$(jq -r '.data.company.type // ""' "$f_ipinfo" 2>/dev/null)
    t_ipreg_use=$(jq -r '.connection.type // ""' "$f_ipreg" 2>/dev/null)
    t_ipreg_com=$(jq -r '.company.type // ""' "$f_ipreg" 2>/dev/null)
    t_ip2loc_use=$(jq -r '.usage_type // ""' "$f_ip2loc" 2>/dev/null)
    t_ip2loc_com=$(jq -r '.as_info.as_usage_type // ""' "$f_ip2loc" 2>/dev/null)
    t_pcheck=$(jq -r --arg ip "$ip" '.[$ip].type // ""' "$f_pcheck" 2>/dev/null)
    if [[ -f "$f_ipapi_is" ]]; then
        t_ipapi_is_use=$(jq -r '.asn.type // ""' "$f_ipapi_is" 2>/dev/null)
        t_ipapi_is_com=$(jq -r '.company.type // ""' "$f_ipapi_is" 2>/dev/null)
    fi
    if [[ -f "$f_abuse" ]]; then
        t_abuse_use=$(jq -r '.data.usageType // ""' "$f_abuse" 2>/dev/null)
    fi

    # 各库风险分（免Key直连: IP2Location / Scamalytics / ProxyCheck / IPQuery / DB-IP；扩展Key: ipapi.is / AbuseIPDB / IPQS）
    local s_ip2loc="" s_scam="" s_pcheck="" s_ipquery="" s_dbip_lvl="" s_dbip_num=""
    local s_ipapi_raw="" s_ipapi_pct="" s_ipapi_bar="" s_ipapi_risk_txt="" s_ipapi_color=""
    local s_abuse="" s_ipqs=""
    s_ip2loc=$(jq -r 'if .fraud_score == null then "" else (.fraud_score|tostring) end' "$f_ip2loc" 2>/dev/null)
    s_scam=$(jq -r '.score // ""' "$f_scam" 2>/dev/null)
    s_pcheck=$(jq -r --arg ip "$ip" '.[$ip].risk // ""' "$f_pcheck" 2>/dev/null)
    s_ipquery=$(jq -r '.risk.risk_score // ""' "$f_ipquery" 2>/dev/null)
    s_dbip_lvl=$(jq -r '.threatLevel // ""' "$f_dbip" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    case "$s_dbip_lvl" in
        low)    s_dbip_num="10" ;;
        medium) s_dbip_num="50" ;;
        high)   s_dbip_num="90" ;;
        *)      s_dbip_lvl=""; s_dbip_num="" ;;
    esac

    if [[ -f "$f_ipapi_is" ]]; then
        s_ipapi_raw=$(jq -r '.company.abuser_score // .asn.abuser_score // ""' "$f_ipapi_is" 2>/dev/null)
        if [[ -n "$s_ipapi_raw" && "$s_ipapi_raw" != "null" ]]; then
            local s_ipapi_num s_ipapi_lbl
            s_ipapi_num=$(echo "$s_ipapi_raw" | awk '{print $1}')
            s_ipapi_lbl=$(echo "$s_ipapi_raw" | awk -F'[()]' '{print $2}')
            if [[ "$s_ipapi_num" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                s_ipapi_pct=$(awk -v n="$s_ipapi_num" 'BEGIN { printf "%.2f%%", n * 100 }')
                s_ipapi_bar=$(awk -v n="$s_ipapi_num" 'BEGIN {
                    v = n * 10000
                    if (v <= 85) b = int(v * 33 / 85 + 0.5)
                    else if (v <= 300) b = int(33 + (v - 85) * 33 / 215 + 0.5)
                    else b = int(66 + (v - 300) * 34 / 9700 + 0.5)
                    if (b < 0) b = 0
                    if (b > 100) b = 100
                    print b
                }')
                case "$s_ipapi_lbl" in
                    "Very Low")  s_ipapi_color="$C_GREEN";  [[ "$LANG_CODE" == "en" ]] && s_ipapi_risk_txt="VeryLow"  || s_ipapi_risk_txt="极低风险" ;;
                    "Low")       s_ipapi_color="$C_GREEN";  [[ "$LANG_CODE" == "en" ]] && s_ipapi_risk_txt="Low"      || s_ipapi_risk_txt="低风险" ;;
                    "Elevated")  s_ipapi_color="$C_YELLOW"; [[ "$LANG_CODE" == "en" ]] && s_ipapi_risk_txt="Elevated" || s_ipapi_risk_txt="较高风险" ;;
                    "High")      s_ipapi_color="$C_RED";    [[ "$LANG_CODE" == "en" ]] && s_ipapi_risk_txt="High"     || s_ipapi_risk_txt="高风险" ;;
                    "Very High") s_ipapi_color="$C_RED";    [[ "$LANG_CODE" == "en" ]] && s_ipapi_risk_txt="VeryHigh" || s_ipapi_risk_txt="极高风险" ;;
                esac
            fi
        fi
    fi

    [[ -f "$f_abuse" ]] && s_abuse=$(jq -r '.data.abuseConfidenceScore // ""' "$f_abuse" 2>/dev/null)
    [[ -f "$f_ipqs" ]]  && s_ipqs=$(jq -r '.fraud_score // ""' "$f_ipqs" 2>/dev/null)

    # 风险因子矩阵（8 大免Key直连源: IP2Loc / IPinfo / ipreg / Scamal / ProxyCh / IPQuery / IP-API / DB-IP）
    local cc_i2 cc_ii cc_ir cc_sc cc_pc cc_iq cc_ia cc_db
    cc_i2=$(jq -r '.country_code // "N/A"' "$f_ip2loc" 2>/dev/null)
    cc_ii=$(jq -r '.data.country // "N/A"' "$f_ipinfo" 2>/dev/null)
    cc_ir=$(jq -r '.location.country.code // "N/A"' "$f_ipreg" 2>/dev/null)
    cc_sc=$(jq -r '.country // "N/A"' "$f_scam" 2>/dev/null); [[ -z "$cc_sc" ]] && cc_sc="N/A"
    cc_pc=$(jq -r --arg ip "$ip" '.[$ip].isocode // "N/A"' "$f_pcheck" 2>/dev/null)
    cc_iq=$(jq -r '.location.country_code // "N/A"' "$f_ipquery" 2>/dev/null)
    cc_ia=$(jq -r '.countryCode // "N/A"' "$f_ipapi" 2>/dev/null)
    cc_db=$(jq -r '.countryCode // "N/A"' "$f_dbip" 2>/dev/null)

    local px_i2 px_ii px_ir px_sc px_pc px_iq px_ia px_db
    px_i2=$(jq -r 'if (.is_proxy == null and .proxy.is_public_proxy == null and .proxy.is_web_proxy == null) then "null" elif (.is_proxy == true or .proxy.is_public_proxy == true or .proxy.is_web_proxy == true or .proxy.is_residential_proxy == true) then "true" else "false" end' "$f_ip2loc" 2>/dev/null)
    px_ii=$(jq -r 'if .data.privacy.proxy == null then "null" else (.data.privacy.proxy|tostring) end' "$f_ipinfo" 2>/dev/null)
    px_ir=$(jq -r 'if (.security.is_proxy == null and .security.is_residential_proxy == null) then "null" elif (.security.is_proxy == true or .security.is_residential_proxy == true) then "true" else "false" end' "$f_ipreg" 2>/dev/null)
    px_sc=$(jq -r '.proxy // "null"' "$f_scam" 2>/dev/null)
    px_pc=$(jq -r --arg ip "$ip" '.[$ip].proxy // "null"' "$f_pcheck" 2>/dev/null)
    px_iq=$(jq -r 'if .risk.is_proxy == null then "null" else (.risk.is_proxy|tostring) end' "$f_ipquery" 2>/dev/null)
    px_ia=$(jq -r 'if .proxy == null then "null" else (.proxy|tostring) end' "$f_ipapi" 2>/dev/null)
    px_db=$(jq -r 'if .isProxy == null then "null" else (.isProxy|tostring) end' "$f_dbip" 2>/dev/null)

    local tor_i2 tor_ii tor_ir tor_sc tor_iq
    tor_i2=$(jq -r 'if .proxy.is_tor == null then "null" else (.proxy.is_tor|tostring) end' "$f_ip2loc" 2>/dev/null)
    tor_ii=$(jq -r 'if .data.privacy.tor == null then "null" else (.data.privacy.tor|tostring) end' "$f_ipinfo" 2>/dev/null)
    tor_ir=$(jq -r 'if (.security.is_tor == null and .security.is_tor_exit == null) then "null" elif (.security.is_tor == true or .security.is_tor_exit == true) then "true" else "false" end' "$f_ipreg" 2>/dev/null)
    tor_sc=$(jq -r '.tor // "null"' "$f_scam" 2>/dev/null)
    tor_iq=$(jq -r 'if .risk.is_tor == null then "null" else (.risk.is_tor|tostring) end' "$f_ipquery" 2>/dev/null)

    local vpn_i2 vpn_ii vpn_ir vpn_sc vpn_pc vpn_iq
    vpn_i2=$(jq -r 'if .proxy.is_vpn == null then "null" else (.proxy.is_vpn|tostring) end' "$f_ip2loc" 2>/dev/null)
    vpn_ii=$(jq -r 'if .data.privacy.vpn == null then "null" else (.data.privacy.vpn|tostring) end' "$f_ipinfo" 2>/dev/null)
    vpn_ir=$(jq -r 'if .security.is_vpn == null then "null" else (.security.is_vpn|tostring) end' "$f_ipreg" 2>/dev/null)
    vpn_sc=$(jq -r '.vpn // "null"' "$f_scam" 2>/dev/null)
    vpn_pc="null"; [[ "$(echo "$t_pcheck" | tr '[:upper:]' '[:lower:]')" == "vpn" ]] && vpn_pc="true" || { [[ -n "$t_pcheck" ]] && vpn_pc="false"; }
    vpn_iq=$(jq -r 'if .risk.is_vpn == null then "null" else (.risk.is_vpn|tostring) end' "$f_ipquery" 2>/dev/null)

    local srv_i2 srv_ii srv_ir srv_sc srv_pc srv_iq srv_ia
    srv_i2=$(jq -r 'if .proxy.is_data_center == null then "null" else (.proxy.is_data_center|tostring) end' "$f_ip2loc" 2>/dev/null)
    srv_ii=$(jq -r 'if .data.privacy.hosting == null then "null" else (.data.privacy.hosting|tostring) end' "$f_ipinfo" 2>/dev/null)
    srv_ir=$(jq -r 'if .security.is_cloud_provider == null then "null" else (.security.is_cloud_provider|tostring) end' "$f_ipreg" 2>/dev/null)
    srv_sc=$(jq -r '.server // "null"' "$f_scam" 2>/dev/null)
    srv_pc="null"; [[ "$(echo "$t_pcheck" | tr '[:upper:]' '[:lower:]')" == *"hosting"* ]] && srv_pc="true" || { [[ -n "$t_pcheck" ]] && srv_pc="false"; }
    srv_iq=$(jq -r 'if .risk.is_datacenter == null then "null" else (.risk.is_datacenter|tostring) end' "$f_ipquery" 2>/dev/null)
    srv_ia=$(jq -r 'if .hosting == null then "null" else (.hosting|tostring) end' "$f_ipapi" 2>/dev/null)

    local abu_i2 abu_ir abu_sc
    abu_i2=$(jq -r 'if .proxy.is_spammer == null then "null" else (.proxy.is_spammer|tostring) end' "$f_ip2loc" 2>/dev/null)
    abu_ir=$(jq -r 'if (.security.is_abuser == null and .security.is_attacker == null and .security.is_threat == null) then "null" elif (.security.is_abuser == true or .security.is_attacker == true or .security.is_threat == true) then "true" else "false" end' "$f_ipreg" 2>/dev/null)
    abu_sc=$(jq -r '.abuser // "null"' "$f_scam" 2>/dev/null)

    local mob_i2 mob_ii mob_iq mob_ia
    mob_i2="null"
    if [[ -n "$t_ip2loc_use" && "$t_ip2loc_use" != "-" ]]; then
        [[ "$t_ip2loc_use" == *"MOB"* ]] && mob_i2="true" || mob_i2="false"
    fi
    mob_ii=$(jq -r 'if .data.is_mobile == null then "null" else (.data.is_mobile|tostring) end' "$f_ipinfo" 2>/dev/null)
    mob_iq=$(jq -r 'if .risk.is_mobile == null then "null" else (.risk.is_mobile|tostring) end' "$f_ipquery" 2>/dev/null)
    mob_ia=$(jq -r 'if .mobile == null then "null" else (.mobile|tostring) end' "$f_ipapi" 2>/dev/null)

    local rob_i2 rob_sc rob_db
    rob_i2=$(jq -r 'if (.proxy.is_web_crawler == null and .proxy.is_scanner == null and .proxy.is_botnet == null) then "null" elif (.proxy.is_web_crawler == true or .proxy.is_ai_crawler == true or .proxy.is_scanner == true or .proxy.is_botnet == true) then "true" else "false" end' "$f_ip2loc" 2>/dev/null)
    rob_sc=$(jq -r '.robot // "null"' "$f_scam" 2>/dev/null)
    rob_db=$(jq -r 'if .isCrawler == null then "null" else (.isCrawler|tostring) end' "$f_dbip" 2>/dev/null)

    # 可选扩展库风险因子（ipapi.is / AbuseIPDB / ipdata / IPQS）
    local cc_is="N/A" px_is="null" tor_is="null" vpn_is="null" srv_is="null" abu_is="null" mob_is="null" rob_is="null"
    local cc_ab="N/A" tor_ab="null" abu_ab="null"
    local cc_id="N/A" px_id="null" tor_id="null" srv_id="null" abu_id="null"
    local cc_qs="N/A" px_qs="null" tor_qs="null" vpn_qs="null" abu_qs="null" mob_qs="null" rob_qs="null"

    if [[ -f "$f_ipapi_is" ]]; then
        cc_is=$(jq -r '.location.country_code // "N/A"' "$f_ipapi_is" 2>/dev/null)
        px_is=$(jq -r 'if .is_proxy == null then "null" else (.is_proxy|tostring) end' "$f_ipapi_is" 2>/dev/null)
        tor_is=$(jq -r 'if .is_tor == null then "null" else (.is_tor|tostring) end' "$f_ipapi_is" 2>/dev/null)
        vpn_is=$(jq -r 'if .is_vpn == null then "null" else (.is_vpn|tostring) end' "$f_ipapi_is" 2>/dev/null)
        srv_is=$(jq -r 'if .is_datacenter == null then "null" else (.is_datacenter|tostring) end' "$f_ipapi_is" 2>/dev/null)
        abu_is=$(jq -r 'if .is_abuser == null then "null" else (.is_abuser|tostring) end' "$f_ipapi_is" 2>/dev/null)
        mob_is=$(jq -r 'if .is_mobile == null then "null" else (.is_mobile|tostring) end' "$f_ipapi_is" 2>/dev/null)
        rob_is=$(jq -r 'if .is_crawler == null then "null" else (.is_crawler|tostring) end' "$f_ipapi_is" 2>/dev/null)
    fi
    if [[ -f "$f_abuse" ]]; then
        cc_ab=$(jq -r '.data.countryCode // "N/A"' "$f_abuse" 2>/dev/null)
        tor_ab=$(jq -r 'if .data.isTor == null then "null" else (.data.isTor|tostring) end' "$f_abuse" 2>/dev/null)
        abu_ab=$(jq -r 'if .data.abuseConfidenceScore == null then "null" elif (.data.abuseConfidenceScore >= 10) then "true" else "false" end' "$f_abuse" 2>/dev/null)
    fi
    if [[ -f "$f_ipdata" ]]; then
        cc_id=$(jq -r '.country_code // "N/A"' "$f_ipdata" 2>/dev/null)
        px_id=$(jq -r 'if .threat.is_proxy == null then "null" else (.threat.is_proxy|tostring) end' "$f_ipdata" 2>/dev/null)
        tor_id=$(jq -r 'if .threat.is_tor == null then "null" else (.threat.is_tor|tostring) end' "$f_ipdata" 2>/dev/null)
        srv_id=$(jq -r 'if .threat.is_datacenter == null then "null" else (.threat.is_datacenter|tostring) end' "$f_ipdata" 2>/dev/null)
        abu_id=$(jq -r 'if (.threat.is_threat == null and .threat.is_known_abuser == null and .threat.is_known_attacker == null) then "null" elif (.threat.is_threat == true or .threat.is_known_abuser == true or .threat.is_known_attacker == true) then "true" else "false" end' "$f_ipdata" 2>/dev/null)
    fi
    if [[ -f "$f_ipqs" ]]; then
        cc_qs=$(jq -r '.country_code // "N/A"' "$f_ipqs" 2>/dev/null)
        px_qs=$(jq -r 'if .proxy == null then "null" else (.proxy|tostring) end' "$f_ipqs" 2>/dev/null)
        tor_qs=$(jq -r 'if .tor == null then "null" else (.tor|tostring) end' "$f_ipqs" 2>/dev/null)
        vpn_qs=$(jq -r 'if .vpn == null then "null" else (.vpn|tostring) end' "$f_ipqs" 2>/dev/null)
        abu_qs=$(jq -r 'if .recent_abuse == null then "null" else (.recent_abuse|tostring) end' "$f_ipqs" 2>/dev/null)
        mob_qs=$(jq -r 'if .mobile == null then "null" else (.mobile|tostring) end' "$f_ipqs" 2>/dev/null)
        rob_qs=$(jq -r 'if .bot_status == null then "null" else (.bot_status|tostring) end' "$f_ipqs" 2>/dev/null)
    fi

    # StopForumSpam 垃圾源情报
    local sfs_appears=0 sfs_freq=0 sfs_conf="0"
    sfs_appears=$(jq -r '.ip.appears // 0' "$f_sfs" 2>/dev/null || echo 0)
    sfs_freq=$(jq -r '.ip.frequency // 0' "$f_sfs" 2>/dev/null || echo 0)
    sfs_conf=$(jq -r '.ip.confidence // 0' "$f_sfs" 2>/dev/null || echo 0)
    [[ ! "$sfs_appears" =~ ^[0-9]+$ ]] && sfs_appears=0
    [[ ! "$sfs_freq" =~ ^[0-9]+$ ]] && sfs_freq=0

    # DNSBL 结果
    local dnsbl_total=0 dnsbl_clean=0 dnsbl_hits=0 dnsbl_mode="N/A" dnsbl_hit_names=""
    if [[ "$stack" == "4" && -f "${run_dir}/dnsbl_summary.txt" ]]; then
        IFS='|' read -r dnsbl_total dnsbl_clean dnsbl_hits dnsbl_mode < "${run_dir}/dnsbl_summary.txt"
        if [[ -s "${run_dir}/dnsbl_hits.txt" ]]; then
            dnsbl_hit_names=$(awk -F'|' '{print $1}' "${run_dir}/dnsbl_hits.txt" | tr '\n' ',' | sed 's/,$//')
        fi
    fi

    # 邮局 25 端口结果
    local mail_local="skipped" mail_ok_cnt=0 mail_ok_list="" mail_fail_list=""
    if [[ -f "${run_dir}/mail_summary.txt" ]]; then
        IFS='|' read -r mail_local mail_ok_cnt mail_ok_list mail_fail_list < "${run_dir}/mail_summary.txt"
    fi

    # 计算综合风险分（平均全部可用风险分 + DNSBL 命中惩罚 + StopForumSpam 滥用惩罚）
    local score_sum=0 score_cnt=0 sc
    for sc in "$s_ip2loc" "$s_scam" "$s_pcheck" "$s_ipquery" "$s_dbip_num" "$s_ipapi_bar" "$s_abuse" "$s_ipqs"; do
        if [[ "$sc" =~ ^[0-9]+$ ]]; then
            score_sum=$((score_sum + sc))
            score_cnt=$((score_cnt + 1))
        fi
    done
    local avg_score=0
    if (( score_cnt > 0 )); then
        avg_score=$((score_sum / score_cnt))
    fi
    if (( dnsbl_hits > 0 )); then
        avg_score=$((avg_score + dnsbl_hits * 15))
    fi
    if (( sfs_appears > 0 )); then
        avg_score=$((avg_score + 15))
    fi
    (( avg_score > 100 )) && avg_score=100

    # 原生 vs 广播判定
    local geo_type_code="unknown"
    if [[ -n "$country_code" && -n "$reg_country" ]]; then
        if [[ "$country_code" == "$reg_country" ]]; then
            geo_type_code="native"
        else
            geo_type_code="broadcast"
        fi
    fi

    # 本地化国家/洲际显示字符串
    local continent_name="" country_disp="" reg_country_disp=""
    [[ -n "$continent_code" ]] && continent_name=$(lookup_continent_name "$continent_code")
    if [[ -n "$country_code" ]]; then
        country_disp=$(format_country_display "$country_code" "$country_name")
        if [[ -n "$continent_code" && -n "$continent_name" ]]; then
            if [[ "$LANG_CODE" == "en" ]]; then
                country_disp="${country_disp}, [${continent_code}] ${continent_name}"
            else
                country_disp="${country_disp}，[${continent_code}]${continent_name}"
            fi
        fi
    else
        country_disp="N/A"
    fi
    if [[ -n "$reg_country" ]]; then
        reg_country_disp=$(format_country_display "$reg_country")
    fi

    # 城市完整组合（州/省, 城市, 邮编）
    local city_disp=""
    if [[ -n "$region_name" && -n "$city_name" && "$region_name" != "$city_name" ]]; then
        city_disp="${region_name}, ${city_name}"
    elif [[ -n "$city_name" ]]; then
        city_disp="$city_name"
    elif [[ -n "$region_name" ]]; then
        city_disp="$region_name"
    fi
    if [[ -n "$postal_code" ]]; then
        [[ -n "$city_disp" ]] && city_disp="${city_disp}, ${postal_code}" || city_disp="$postal_code"
    fi
    [[ -z "$city_disp" ]] && city_disp="N/A"

    # 读取流媒体/AI 结果
    local m_chatgpt_s="" m_chatgpt_r="" m_claude_s="" m_claude_r="" m_gemini_s="" m_gemini_r=""
    local m_netflix_s="" m_netflix_r="" m_disney_s="" m_disney_r="" m_youtube_s="" m_youtube_r=""
    local m_tiktok_s="" m_tiktok_r="" m_prime_s="" m_prime_r="" m_reddit_s="" m_reddit_r=""
    if [[ "$SKIP_MEDIA" -eq 0 ]]; then
        [[ -f "${run_dir}/m_chatgpt.txt" ]] && IFS='|' read -r m_chatgpt_s m_chatgpt_r < "${run_dir}/m_chatgpt.txt"
        [[ -f "${run_dir}/m_claude.txt" ]]  && IFS='|' read -r m_claude_s m_claude_r < "${run_dir}/m_claude.txt"
        [[ -f "${run_dir}/m_gemini.txt" ]]  && IFS='|' read -r m_gemini_s m_gemini_r < "${run_dir}/m_gemini.txt"
        [[ -f "${run_dir}/m_netflix.txt" ]] && IFS='|' read -r m_netflix_s m_netflix_r < "${run_dir}/m_netflix.txt"
        [[ -f "${run_dir}/m_disney.txt" ]]  && IFS='|' read -r m_disney_s m_disney_r < "${run_dir}/m_disney.txt"
        [[ -f "${run_dir}/m_youtube.txt" ]] && IFS='|' read -r m_youtube_s m_youtube_r < "${run_dir}/m_youtube.txt"
        [[ -f "${run_dir}/m_tiktok.txt" ]]  && IFS='|' read -r m_tiktok_s m_tiktok_r < "${run_dir}/m_tiktok.txt"
        [[ -f "${run_dir}/m_prime.txt" ]]   && IFS='|' read -r m_prime_s m_prime_r < "${run_dir}/m_prime.txt"
        [[ -f "${run_dir}/m_reddit.txt" ]]  && IFS='|' read -r m_reddit_s m_reddit_r < "${run_dir}/m_reddit.txt"
    fi

    local now_time
    if [[ "$LANG_CODE" == "en" ]]; then
        now_time=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
    else
        now_time=$(TZ="Asia/Shanghai" date +"%Y-%m-%d %H:%M:%S CST" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")
    fi

    # IPQuery / IP-API 推导使用类型
    local t_ipquery_use="unknown" t_ipapi_use="unknown"
    if [[ "$mob_iq" == "true" ]]; then
        t_ipquery_use="mobile"
    elif [[ "$vpn_iq" == "true" ]]; then
        t_ipquery_use="vpn"
    elif [[ "$px_iq" == "true" ]]; then
        t_ipquery_use="proxy"
    elif [[ "$srv_iq" == "true" ]]; then
        t_ipquery_use="hosting"
    elif [[ "$srv_iq" == "false" ]]; then
        t_ipquery_use="isp"
    fi

    if [[ "$mob_ia" == "true" ]]; then
        t_ipapi_use="mobile"
    elif [[ "$px_ia" == "true" ]]; then
        t_ipapi_use="proxy"
    elif [[ "$srv_ia" == "true" ]]; then
        t_ipapi_use="hosting"
    elif [[ "$srv_ia" == "false" ]]; then
        t_ipapi_use="isp"
    fi

    # ---------------- 构建结构化 JSON ----------------
    local report_json
    report_json=$(jq -n \
        --arg ver "v${VERSION}" \
        --arg time "$now_time" \
        --arg ip "$display_ip" \
        --arg stack "IPv${stack}" \
        --arg mode "$TARGET_MODE" \
        --arg asn "${asn:-N/A}" \
        --arg org "${org:-N/A}" \
        --arg isp "${isp:-N/A}" \
        --arg cidr "${cidr_disp:-}" \
        --arg rir "${rir:-}" \
        --arg rdns "${rdns:-}" \
        --arg lat "${lat:-}" \
        --arg lon "${lon:-}" \
        --arg dms "${dms:-}" \
        --arg map_url "${map_url:-}" \
        --arg cc "${country_code:-N/A}" \
        --arg cname "${country_name:-N/A}" \
        --arg cont_cc "${continent_code:-}" \
        --arg cont_name "${continent_name:-}" \
        --arg regcc "${reg_country:-N/A}" \
        --arg region "${region_name:-}" \
        --arg city "${city_name:-}" \
        --arg postal "${postal_code:-}" \
        --arg tz "${timezone:-N/A}" \
        --arg geotype "$geo_type_code" \
        --arg anycast "$is_anycast" \
        --arg t_ii_u "${t_ipinfo_use:-N/A}" --arg t_ii_c "${t_ipinfo_com:-N/A}" \
        --arg t_ir_u "${t_ipreg_use:-N/A}" --arg t_ir_c "${t_ipreg_com:-N/A}" \
        --arg t_i2_u "${t_ip2loc_use:-N/A}" --arg t_i2_c "${t_ip2loc_com:-N/A}" \
        --arg t_pc "${t_pcheck:-N/A}" --arg t_iq "${t_ipquery_use:-N/A}" --arg t_ia "${t_ipapi_use:-N/A}" \
        --arg t_is_u "${t_ipapi_is_use:-}" --arg t_is_c "${t_ipapi_is_com:-}" --arg t_ab_u "${t_abuse_use:-}" \
        --arg s_i2 "${s_ip2loc:-}" --arg s_scam "${s_scam:-}" --arg s_pc "${s_pcheck:-}" --arg s_iq "${s_ipquery:-}" \
        --arg s_dbip "${s_dbip_lvl:-}" --arg s_is "${s_ipapi_raw:-}" --arg s_ab "${s_abuse:-}" --arg s_ipqs "${s_ipqs:-}" \
        --argjson avg "$avg_score" \
        --arg cc_i2 "$cc_i2" --arg cc_ii "$cc_ii" --arg cc_ir "$cc_ir" --arg cc_sc "$cc_sc" --arg cc_pc "$cc_pc" --arg cc_iq "$cc_iq" --arg cc_ia "$cc_ia" --arg cc_db "$cc_db" \
        --arg cc_is "$cc_is" --arg cc_ab "$cc_ab" --arg cc_id "$cc_id" --arg cc_qs "$cc_qs" \
        --arg px_i2 "$px_i2" --arg px_ii "$px_ii" --arg px_ir "$px_ir" --arg px_sc "$px_sc" --arg px_pc "$px_pc" --arg px_iq "$px_iq" --arg px_ia "$px_ia" --arg px_db "$px_db" \
        --arg px_is "$px_is" --arg px_id "$px_id" --arg px_qs "$px_qs" \
        --arg tor_i2 "$tor_i2" --arg tor_ii "$tor_ii" --arg tor_ir "$tor_ir" --arg tor_sc "$tor_sc" --arg tor_iq "$tor_iq" \
        --arg tor_is "$tor_is" --arg tor_ab "$tor_ab" --arg tor_id "$tor_id" --arg tor_qs "$tor_qs" \
        --arg vpn_i2 "$vpn_i2" --arg vpn_ii "$vpn_ii" --arg vpn_ir "$vpn_ir" --arg vpn_sc "$vpn_sc" --arg vpn_pc "$vpn_pc" --arg vpn_iq "$vpn_iq" \
        --arg vpn_is "$vpn_is" --arg vpn_qs "$vpn_qs" \
        --arg srv_i2 "$srv_i2" --arg srv_ii "$srv_ii" --arg srv_ir "$srv_ir" --arg srv_sc "$srv_sc" --arg srv_pc "$srv_pc" --arg srv_iq "$srv_iq" --arg srv_ia "$srv_ia" \
        --arg srv_is "$srv_is" --arg srv_id "$srv_id" \
        --arg abu_i2 "$abu_i2" --arg abu_ir "$abu_ir" --arg abu_sc "$abu_sc" --arg abu_is "$abu_is" --arg abu_ab "$abu_ab" --arg abu_id "$abu_id" --arg abu_qs "$abu_qs" \
        --arg mob_i2 "$mob_i2" --arg mob_ii "$mob_ii" --arg mob_iq "$mob_iq" --arg mob_ia "$mob_ia" --arg mob_is "$mob_is" --arg mob_qs "$mob_qs" \
        --arg rob_i2 "$rob_i2" --arg rob_sc "$rob_sc" --arg rob_db "$rob_db" --arg rob_is "$rob_is" --arg rob_qs "$rob_qs" \
        --argjson sfs_app "$sfs_appears" --argjson sfs_frq "$sfs_freq" --arg sfs_cnf "$sfs_conf" \
        --arg cg_s "$m_chatgpt_s" --arg cg_r "$m_chatgpt_r" \
        --arg cl_s "$m_claude_s" --arg cl_r "$m_claude_r" \
        --arg gm_s "$m_gemini_s" --arg gm_r "$m_gemini_r" \
        --arg nf_s "$m_netflix_s" --arg nf_r "$m_netflix_r" \
        --arg ds_s "$m_disney_s" --arg ds_r "$m_disney_r" \
        --arg yt_s "$m_youtube_s" --arg yt_r "$m_youtube_r" \
        --arg tt_s "$m_tiktok_s" --arg tt_r "$m_tiktok_r" \
        --arg pv_s "$m_prime_s" --arg pv_r "$m_prime_r" \
        --arg rd_s "$m_reddit_s" --arg rd_r "$m_reddit_r" \
        --arg mail_loc "$mail_local" --arg mail_ok "$mail_ok_list" --arg mail_fail "$mail_fail_list" \
        --argjson d_tot "$dnsbl_total" --argjson d_cln "$dnsbl_clean" --argjson d_hit "$dnsbl_hits" --arg d_mode "$dnsbl_mode" --arg d_names "$dnsbl_hit_names" \
        '{
            meta: {tool: "IPzhiliang", version: $ver, time: $time, ip: $ip, stack: $stack, mode: $mode, privacy_upload: false},
            basic: {
                asn: $asn, organization: $org, isp: $isp, cidr: $cidr, rir: $rir, rdns: $rdns,
                latitude: $lat, longitude: $lon, dms: $dms, map: $map_url,
                country_code: $cc, country: $cname, continent_code: $cont_cc, continent: $cont_name,
                registered_country: $regcc, region: $region, city: $city, postal: $postal,
                timezone: $tz, ip_origin: $geotype, anycast: ($anycast == "true")
            },
            type: {
                ipinfo_usage: $t_ii_u, ipinfo_company: $t_ii_c,
                ipregistry_usage: $t_ir_u, ipregistry_company: $t_ir_c,
                ip2location_usage: $t_i2_u, ip2location_company: $t_i2_c,
                proxycheck: $t_pc, ipquery: $t_iq, ipapi_com: $t_ia,
                ipapi_is_usage: $t_is_u, ipapi_is_company: $t_is_c, abuseipdb: $t_ab_u
            },
            risk_score: {
                composite: $avg, ip2location: $s_i2, scamalytics: $s_scam, proxycheck: $s_pc,
                ipquery: $s_iq, dbip: $s_dbip, ipapi_is: $s_is, abuseipdb: $s_ab, ipqs: $s_ipqs
            },
            risk_factors: {
                country: {ip2location: $cc_i2, ipinfo: $cc_ii, ipregistry: $cc_ir, scamalytics: $cc_sc, proxycheck: $cc_pc, ipquery: $cc_iq, ipapi_com: $cc_ia, dbip: $cc_db, ipapi_is: $cc_is, abuseipdb: $cc_ab, ipdata: $cc_id, ipqs: $cc_qs},
                proxy: {ip2location: $px_i2, ipinfo: $px_ii, ipregistry: $px_ir, scamalytics: $px_sc, proxycheck: $px_pc, ipquery: $px_iq, ipapi_com: $px_ia, dbip: $px_db, ipapi_is: $px_is, ipdata: $px_id, ipqs: $px_qs},
                tor: {ip2location: $tor_i2, ipinfo: $tor_ii, ipregistry: $tor_ir, scamalytics: $tor_sc, ipquery: $tor_iq, ipapi_is: $tor_is, abuseipdb: $tor_ab, ipdata: $tor_id, ipqs: $tor_qs},
                vpn: {ip2location: $vpn_i2, ipinfo: $vpn_ii, ipregistry: $vpn_ir, scamalytics: $vpn_sc, proxycheck: $vpn_pc, ipquery: $vpn_iq, ipapi_is: $vpn_is, ipqs: $vpn_qs},
                server: {ip2location: $srv_i2, ipinfo: $srv_ii, ipregistry: $srv_ir, scamalytics: $srv_sc, proxycheck: $srv_pc, ipquery: $srv_iq, ipapi_com: $srv_ia, ipapi_is: $srv_is, ipdata: $srv_id},
                abuser: {ip2location: $abu_i2, ipregistry: $abu_ir, scamalytics: $abu_sc, ipapi_is: $abu_is, abuseipdb: $abu_ab, ipdata: $abu_id, ipqs: $abu_qs},
                mobile: {ip2location: $mob_i2, ipinfo: $mob_ii, ipquery: $mob_iq, ipapi_com: $mob_ia, ipapi_is: $mob_is, ipqs: $mob_qs},
                robot: {ip2location: $rob_i2, scamalytics: $rob_sc, dbip: $rob_db, ipapi_is: $rob_is, ipqs: $rob_qs},
                stopforumspam: {appears: $sfs_app, frequency: $sfs_frq, confidence: $sfs_cnf}
            },
            unlock: {
                ChatGPT: {status: $cg_s, region: $cg_r},
                Claude: {status: $cl_s, region: $cl_r},
                Gemini: {status: $gm_s, region: $gm_r},
                Netflix: {status: $nf_s, region: $nf_r},
                DisneyPlus: {status: $ds_s, region: $ds_r},
                YouTube: {status: $yt_s, region: $yt_r},
                TikTok: {status: $tt_s, region: $tt_r},
                PrimeVideo: {status: $pv_s, region: $pv_r},
                Reddit: {status: $rd_s, region: $rd_r}
            },
            mail: {port25_outbound: $mail_loc, reachable_providers: $mail_ok, blocked_providers: $mail_fail},
            dnsbl: {method: $d_mode, total: $d_tot, clean: $d_cln, blacklisted: $d_hit, hits: $d_names}
        }')

    # ---------------- 构建经典 72 列终端彩色报告 ----------------
    local report_ansi_file="${run_dir}/report.ansi"
    {
        local hash_line="########################################################################"
        local eq_line="========================================================================"
        local repo_url="https://github.com/imthnio/IPzhiliang"

        echo -e "${hash_line}"
        if [[ "$LANG_CODE" == "en" ]]; then
            print_centered_72 "IP QUALITY CHECK REPORT: ${display_ip}" "${C_BOLD}IP QUALITY CHECK REPORT: ${C_CYAN}${display_ip}${C_RESET}"
            print_centered_72 "${repo_url}" "${C_UNDERLINE}${repo_url}${C_RESET}"
            print_centered_72 "Report Time: ${now_time}  Version: v${VERSION}" "Report Time: ${now_time}  Version: v${VERSION}"
        else
            print_centered_72 "IP质量体检报告：${display_ip}" "${C_BOLD}IP质量体检报告：${C_CYAN}${display_ip}${C_RESET}"
            print_centered_72 "${repo_url}" "${C_UNDERLINE}${repo_url}${C_RESET}"
            print_centered_72 "报告时间：${now_time}  脚本版本：v${VERSION}  纯本地零上传" "报告时间：${now_time}  脚本版本：v${VERSION}  纯本地零上传"
        fi
        if [[ -n "$ACTIVE_PROXY_DISPLAY" ]]; then
            print_centered_72 "Proxy: ${ACTIVE_PROXY_DISPLAY}" "${C_DIM}Proxy: ${ACTIVE_PROXY_DISPLAY}${C_RESET}"
        elif [[ -n "$ACTIVE_IFACE" ]]; then
            local iface_disp
            iface_disp=$(format_iface_display "$ACTIVE_IFACE")
            print_centered_72 "Interface: ${iface_disp}" "${C_DIM}Interface: ${iface_disp}${C_RESET}"
        fi
        echo -e "${hash_line}"

        # 一、基础信息（完整版：ASN / 组织 / 运营商 / 网段路由 / 反向解析 / DMS 坐标 / 地图 / 城市邮编 / 使用地+洲际 / 注册地 / 时区 / 原生与任播）
        local route_disp=""
        if [[ -n "$cidr_disp" && -n "$rir" ]]; then
            route_disp="${cidr_disp} (${rir})"
        elif [[ -n "$cidr_disp" ]]; then
            route_disp="$cidr_disp"
        elif [[ -n "$rir" ]]; then
            route_disp="$rir"
        fi

        local org_lc isp_lc show_isp=0
        org_lc=$(echo "${org:-}" | tr '[:upper:]' '[:lower:]')
        isp_lc=$(echo "${isp:-}" | tr '[:upper:]' '[:lower:]')
        [[ -n "$isp" && "$isp_lc" != "$org_lc" ]] && show_isp=1

        local basic_src_en="Multi-Source Consensus" basic_src_cn="多源融合数据库"
        if [[ $has_maxmind -eq 1 ]]; then
            basic_src_en="MaxMind + Multi-Source"
            basic_src_cn="MaxMind + 多源融合数据库"
        fi

        if [[ "$LANG_CODE" == "en" ]]; then
            echo -e "1. Basic Information (${C_ITALIC}${basic_src_en}${C_RESET})"
            echo -e "${C_CYAN}ASN:                    ${C_GREEN}${asn:-Not Assigned}${C_RESET}"
            echo -e "${C_CYAN}Organization:           ${C_GREEN}${org:-N/A}${C_RESET}"
            [[ $show_isp -eq 1 ]] && echo -e "${C_CYAN}ISP:                    ${C_GREEN}${isp}${C_RESET}"
            [[ -n "$route_disp" ]] && echo -e "${C_CYAN}Route / RIR:            ${C_GREEN}${route_disp}${C_RESET}"
            [[ -n "$rdns" ]] && echo -e "${C_CYAN}rDNS:                   ${C_GREEN}${rdns}${C_RESET}"
            [[ -n "$dms" ]] && echo -e "${C_CYAN}Location:               ${C_GREEN}${dms}${C_RESET}"
            [[ -n "$map_url" ]] && echo -e "${C_CYAN}Map:                    ${C_UNDERLINE}${C_GREEN}${map_url}${C_RESET}"
            echo -e "${C_CYAN}City:                   ${C_GREEN}${city_disp}${C_RESET}"
            echo -e "${C_CYAN}Actual Region:          ${C_GREEN}${country_disp}${C_RESET}"
            [[ -n "$reg_country_disp" ]] && echo -e "${C_CYAN}Registered Region:      ${C_GREEN}${reg_country_disp}${C_RESET}"
            echo -e "${C_CYAN}Time Zone:              ${C_GREEN}${timezone:-N/A}${C_RESET}"
            if [[ -n "$country_code" && -n "$reg_country" ]]; then
                if [[ "$country_code" == "$reg_country" ]]; then
                    echo -e "${C_CYAN}IP Type:                ${BG_GREEN}${C_BLACK} Geo-consistent ${C_RESET}"
                else
                    echo -e "${C_CYAN}IP Type:                ${BG_RED}${C_BLACK} Geo-discrepant ${C_RESET}"
                fi
            fi
            [[ "$is_anycast" == "true" ]] && echo -e "${C_CYAN}Routing:                ${C_YELLOW}Anycast${C_RESET}"
        else
            echo -e "一、基础信息（${C_ITALIC}${basic_src_cn}${C_RESET}）"
            echo -e "${C_CYAN}自治系统号：            ${C_GREEN}${asn:-未分配}${C_RESET}"
            echo -e "${C_CYAN}组织：                  ${C_GREEN}${org:-N/A}${C_RESET}"
            [[ $show_isp -eq 1 ]] && echo -e "${C_CYAN}运营商：                ${C_GREEN}${isp}${C_RESET}"
            [[ -n "$route_disp" ]] && echo -e "${C_CYAN}网段路由：              ${C_GREEN}${route_disp}${C_RESET}"
            [[ -n "$rdns" ]] && echo -e "${C_CYAN}反向解析：              ${C_GREEN}${rdns}${C_RESET}"
            [[ -n "$dms" ]] && echo -e "${C_CYAN}坐标：                  ${C_GREEN}${dms}${C_RESET}"
            [[ -n "$map_url" ]] && echo -e "${C_CYAN}地图：                  ${C_UNDERLINE}${C_GREEN}${map_url}${C_RESET}"
            echo -e "${C_CYAN}城市：                  ${C_GREEN}${city_disp}${C_RESET}"
            echo -e "${C_CYAN}使用地：                ${C_GREEN}${country_disp}${C_RESET}"
            [[ -n "$reg_country_disp" ]] && echo -e "${C_CYAN}注册地：                ${C_GREEN}${reg_country_disp}${C_RESET}"
            echo -e "${C_CYAN}时区：                  ${C_GREEN}${timezone:-N/A}${C_RESET}"
            if [[ -n "$country_code" && -n "$reg_country" ]]; then
                if [[ "$country_code" == "$reg_country" ]]; then
                    echo -e "${C_CYAN}IP类型：                ${BG_GREEN}${C_BLACK} 原生IP ${C_RESET}"
                else
                    echo -e "${C_CYAN}IP类型：                ${BG_RED}${C_BLACK} 广播IP ${C_RESET}"
                fi
            fi
            [[ "$is_anycast" == "true" ]] && echo -e "${C_CYAN}网络属性：              ${C_YELLOW}Anycast (任播网络)${C_RESET}"
        fi

        # 二、IP类型属性（6 大免Key直连库，总宽 10 + 6*10 = 70 <= 72 列 + 可选扩展库子行）
        if [[ "$LANG_CODE" == "en" ]]; then
            echo -e "2. IP Type"
            echo -e "${C_CYAN}Database: ${C_RESET}${C_ITALIC}  IPinfo  ipregistry  IP2Loc  ProxyCheck  IPQuery   IP-API  ${C_RESET}"
            printf "${C_CYAN}Usage:    ${C_RESET}%b%b%b%b%b%b\n" \
                "$(render_type_cell "$t_ipinfo_use")" "$(render_type_cell "$t_ipreg_use")" "$(render_type_cell "$t_ip2loc_use")" \
                "$(render_type_cell "$t_pcheck")" "$(render_type_cell "$t_ipquery_use")" "$(render_type_cell "$t_ipapi_use")"
            printf "${C_CYAN}Company:  ${C_RESET}%b%b%b%b%b%b\n" \
                "$(render_type_cell "$t_ipinfo_com")" "$(render_type_cell "$t_ipreg_com")" "$(render_type_cell "$t_ip2loc_com")" \
                "$(render_type_cell "")" "$(render_type_cell "")" "$(render_type_cell "")"
        else
            echo -e "二、IP类型属性"
            echo -e "${C_CYAN}数据库：  ${C_RESET}${C_ITALIC}  IPinfo  ipregistry  IP2Loc  ProxyCheck  IPQuery   IP-API  ${C_RESET}"
            printf "${C_CYAN}使用类型：${C_RESET}%b%b%b%b%b%b\n" \
                "$(render_type_cell "$t_ipinfo_use")" "$(render_type_cell "$t_ipreg_use")" "$(render_type_cell "$t_ip2loc_use")" \
                "$(render_type_cell "$t_pcheck")" "$(render_type_cell "$t_ipquery_use")" "$(render_type_cell "$t_ipapi_use")"
            printf "${C_CYAN}公司类型：${C_RESET}%b%b%b%b%b%b\n" \
                "$(render_type_cell "$t_ipinfo_com")" "$(render_type_cell "$t_ipreg_com")" "$(render_type_cell "$t_ip2loc_com")" \
                "$(render_type_cell "")" "$(render_type_cell "")" "$(render_type_cell "")"
        fi
        if [[ -n "$t_ipapi_is_use" || -n "$t_ipapi_is_com" || -n "$t_abuse_use" ]]; then
            local ext_t_hdr="" ext_t_use="" ext_t_com=""
            if [[ -n "$t_ipapi_is_use" || -n "$t_ipapi_is_com" ]]; then
                ext_t_hdr+=" ipapi.is "
                ext_t_use+="$(render_type_cell "$t_ipapi_is_use")"
                ext_t_com+="$(render_type_cell "$t_ipapi_is_com")"
            fi
            if [[ -n "$t_abuse_use" ]]; then
                ext_t_hdr+="AbuseIPDB "
                ext_t_use+="$(render_type_cell "$t_abuse_use")"
                ext_t_com+="$(render_type_cell "")"
            fi
            if [[ "$LANG_CODE" == "en" ]]; then
                echo -e "${C_CYAN}Ext. DBs: ${C_RESET}${C_ITALIC}${ext_t_hdr}${C_RESET}"
                printf "${C_CYAN}Usage:    ${C_RESET}%b\n" "$ext_t_use"
                printf "${C_CYAN}Company:  ${C_RESET}%b\n" "$ext_t_com"
            else
                echo -e "${C_CYAN}扩展库：  ${C_RESET}${C_ITALIC}${ext_t_hdr}${C_RESET}"
                printf "${C_CYAN}使用类型：${C_RESET}%b\n" "$ext_t_use"
                printf "${C_CYAN}公司类型：${C_RESET}%b\n" "$ext_t_com"
            fi
        fi

        # 三、风险评分（经典三色渐变热力条 + 紧随进度条后的分值与风险等级）
        local dbip_risk_disp="" dbip_risk_color=""
        if [[ -n "$s_dbip_num" ]]; then
            case "$s_dbip_lvl" in
                low)    dbip_risk_color="$C_GREEN";  [[ "$LANG_CODE" == "en" ]] && dbip_risk_disp="Low"    || dbip_risk_disp="低风险" ;;
                medium) dbip_risk_color="$C_YELLOW"; [[ "$LANG_CODE" == "en" ]] && dbip_risk_disp="Medium" || dbip_risk_disp="中风险" ;;
                high)   dbip_risk_color="$C_RED";    [[ "$LANG_CODE" == "en" ]] && dbip_risk_disp="High"   || dbip_risk_disp="高风险" ;;
            esac
        fi

        if [[ "$LANG_CODE" == "en" ]]; then
            echo -e "3. Risk Score"
            echo -e "${C_CYAN}Levels:         ${C_BLACK}${BG_GREEN} VeryLow  Low ${BG_YELLOW}    Medium    ${BG_RED} High VeryHigh${C_RESET}"
            [[ "$s_ip2loc" =~ ^[0-9]+$ ]]   && printf "${C_CYAN}IP2Location:    ${C_RESET}%b\n" "$(render_risk_bar "$s_ip2loc")"
            [[ "$s_scam" =~ ^[0-9]+$ ]]     && printf "${C_CYAN}Scamalytics:    ${C_RESET}%b\n" "$(render_risk_bar "$s_scam")"
            [[ "$s_pcheck" =~ ^[0-9]+$ ]]   && printf "${C_CYAN}ProxyCheck:     ${C_RESET}%b\n" "$(render_risk_bar "$s_pcheck")"
            [[ "$s_ipquery" =~ ^[0-9]+$ ]]  && printf "${C_CYAN}IPQuery:        ${C_RESET}%b\n" "$(render_risk_bar "$s_ipquery")"
            [[ -n "$s_dbip_num" ]]          && printf "${C_CYAN}DB-IP:          ${C_RESET}%b\n" "$(render_risk_bar "$s_dbip_num" "-" "$dbip_risk_disp" "$dbip_risk_color")"
            [[ "$s_ipapi_bar" =~ ^[0-9]+$ ]] && printf "${C_CYAN}ipapi.is:       ${C_RESET}%b\n" "$(render_risk_bar "$s_ipapi_bar" "$s_ipapi_pct" "$s_ipapi_risk_txt" "$s_ipapi_color")"
            [[ "$s_abuse" =~ ^[0-9]+$ ]]    && printf "${C_CYAN}AbuseIPDB:      ${C_RESET}%b\n" "$(render_risk_bar "$s_abuse")"
            [[ "$s_ipqs" =~ ^[0-9]+$ ]]     && printf "${C_CYAN}IPQS:           ${C_RESET}%b\n" "$(render_risk_bar "$s_ipqs")"
            printf "${C_CYAN}${C_BOLD}Composite:      ${C_RESET}%b\n" "$(render_risk_bar "$avg_score")"
        else
            echo -e "三、风险评分"
            echo -e "${C_CYAN}风险等级：      ${C_BLACK}${BG_GREEN} 极低      低 ${BG_YELLOW}     中等     ${BG_RED} 高      极高 ${C_RESET}"
            [[ "$s_ip2loc" =~ ^[0-9]+$ ]]   && printf "${C_CYAN}IP2Location：   ${C_RESET}%b\n" "$(render_risk_bar "$s_ip2loc")"
            [[ "$s_scam" =~ ^[0-9]+$ ]]     && printf "${C_CYAN}Scamalytics：   ${C_RESET}%b\n" "$(render_risk_bar "$s_scam")"
            [[ "$s_pcheck" =~ ^[0-9]+$ ]]   && printf "${C_CYAN}ProxyCheck：    ${C_RESET}%b\n" "$(render_risk_bar "$s_pcheck")"
            [[ "$s_ipquery" =~ ^[0-9]+$ ]]  && printf "${C_CYAN}IPQuery：       ${C_RESET}%b\n" "$(render_risk_bar "$s_ipquery")"
            [[ -n "$s_dbip_num" ]]          && printf "${C_CYAN}DB-IP：         ${C_RESET}%b\n" "$(render_risk_bar "$s_dbip_num" "-" "$dbip_risk_disp" "$dbip_risk_color")"
            [[ "$s_ipapi_bar" =~ ^[0-9]+$ ]] && printf "${C_CYAN}ipapi.is：      ${C_RESET}%b\n" "$(render_risk_bar "$s_ipapi_bar" "$s_ipapi_pct" "$s_ipapi_risk_txt" "$s_ipapi_color")"
            [[ "$s_abuse" =~ ^[0-9]+$ ]]    && printf "${C_CYAN}AbuseIPDB：     ${C_RESET}%b\n" "$(render_risk_bar "$s_abuse")"
            [[ "$s_ipqs" =~ ^[0-9]+$ ]]     && printf "${C_CYAN}IPQS：          ${C_RESET}%b\n" "$(render_risk_bar "$s_ipqs")"
            printf "${C_CYAN}${C_BOLD}综合评级：      ${C_RESET}%b\n" "$(render_risk_bar "$avg_score")"
        fi

        # 四、风险因子（8 大免Key直连库，总宽 8 + 8*8 = 72 列精确对齐 + 可选扩展库子表）
        if [[ "$LANG_CODE" == "en" ]]; then
            echo -e "4. Risk Factors"
            echo -e "${C_CYAN}DB:     ${C_RESET}${C_ITALIC} IP2Loc  IPinfo  ipreg   Scamal ProxyCh IPQuery  IP-API  DB-IP  ${C_RESET}"
            printf "${C_CYAN}Region: ${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_cc "$cc_i2")" "$(render_factor_cc "$cc_ii")" "$(render_factor_cc "$cc_ir")" "$(render_factor_cc "$cc_sc")" "$(render_factor_cc "$cc_pc")" "$(render_factor_cc "$cc_iq")" "$(render_factor_cc "$cc_ia")" "$(render_factor_cc "$cc_db")"
            printf "${C_CYAN}Proxy:  ${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_bool "$px_i2")" "$(render_factor_bool "$px_ii")" "$(render_factor_bool "$px_ir")" "$(render_factor_bool "$px_sc")" "$(render_factor_bool "$px_pc")" "$(render_factor_bool "$px_iq")" "$(render_factor_bool "$px_ia")" "$(render_factor_bool "$px_db")"
            printf "${C_CYAN}Tor:    ${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_bool "$tor_i2")" "$(render_factor_bool "$tor_ii")" "$(render_factor_bool "$tor_ir")" "$(render_factor_bool "$tor_sc")" "$(render_factor_bool "null")" "$(render_factor_bool "$tor_iq")" "$(render_factor_bool "null")" "$(render_factor_bool "null")"
            printf "${C_CYAN}VPN:    ${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_bool "$vpn_i2")" "$(render_factor_bool "$vpn_ii")" "$(render_factor_bool "$vpn_ir")" "$(render_factor_bool "$vpn_sc")" "$(render_factor_bool "$vpn_pc")" "$(render_factor_bool "$vpn_iq")" "$(render_factor_bool "null")" "$(render_factor_bool "null")"
            printf "${C_CYAN}Server: ${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_bool "$srv_i2")" "$(render_factor_bool "$srv_ii")" "$(render_factor_bool "$srv_ir")" "$(render_factor_bool "$srv_sc")" "$(render_factor_bool "$srv_pc")" "$(render_factor_bool "$srv_iq")" "$(render_factor_bool "$srv_ia")" "$(render_factor_bool "null")"
            printf "${C_CYAN}Abuser: ${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_bool "$abu_i2")" "$(render_factor_bool "null")" "$(render_factor_bool "$abu_ir")" "$(render_factor_bool "$abu_sc")" "$(render_factor_bool "null")" "$(render_factor_bool "null")" "$(render_factor_bool "null")" "$(render_factor_bool "null")"
            printf "${C_CYAN}Mobile: ${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_bool "$mob_i2")" "$(render_factor_bool "$mob_ii")" "$(render_factor_bool "null")" "$(render_factor_bool "null")" "$(render_factor_bool "null")" "$(render_factor_bool "$mob_iq")" "$(render_factor_bool "$mob_ia")" "$(render_factor_bool "null")"
            printf "${C_CYAN}Robot:  ${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_bool "$rob_i2")" "$(render_factor_bool "null")" "$(render_factor_bool "null")" "$(render_factor_bool "$rob_sc")" "$(render_factor_bool "null")" "$(render_factor_bool "null")" "$(render_factor_bool "null")" "$(render_factor_bool "$rob_db")"
        else
            echo -e "四、风险因子"
            echo -e "${C_CYAN}库：    ${C_RESET}${C_ITALIC} IP2Loc  IPinfo  ipreg   Scamal ProxyCh IPQuery  IP-API  DB-IP  ${C_RESET}"
            printf "${C_CYAN}地区：  ${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_cc "$cc_i2")" "$(render_factor_cc "$cc_ii")" "$(render_factor_cc "$cc_ir")" "$(render_factor_cc "$cc_sc")" "$(render_factor_cc "$cc_pc")" "$(render_factor_cc "$cc_iq")" "$(render_factor_cc "$cc_ia")" "$(render_factor_cc "$cc_db")"
            printf "${C_CYAN}代理：  ${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_bool "$px_i2")" "$(render_factor_bool "$px_ii")" "$(render_factor_bool "$px_ir")" "$(render_factor_bool "$px_sc")" "$(render_factor_bool "$px_pc")" "$(render_factor_bool "$px_iq")" "$(render_factor_bool "$px_ia")" "$(render_factor_bool "$px_db")"
            printf "${C_CYAN}Tor：   ${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_bool "$tor_i2")" "$(render_factor_bool "$tor_ii")" "$(render_factor_bool "$tor_ir")" "$(render_factor_bool "$tor_sc")" "$(render_factor_bool "null")" "$(render_factor_bool "$tor_iq")" "$(render_factor_bool "null")" "$(render_factor_bool "null")"
            printf "${C_CYAN}VPN：   ${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_bool "$vpn_i2")" "$(render_factor_bool "$vpn_ii")" "$(render_factor_bool "$vpn_ir")" "$(render_factor_bool "$vpn_sc")" "$(render_factor_bool "$vpn_pc")" "$(render_factor_bool "$vpn_iq")" "$(render_factor_bool "null")" "$(render_factor_bool "null")"
            printf "${C_CYAN}服务器：${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_bool "$srv_i2")" "$(render_factor_bool "$srv_ii")" "$(render_factor_bool "$srv_ir")" "$(render_factor_bool "$srv_sc")" "$(render_factor_bool "$srv_pc")" "$(render_factor_bool "$srv_iq")" "$(render_factor_bool "$srv_ia")" "$(render_factor_bool "null")"
            printf "${C_CYAN}滥用：  ${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_bool "$abu_i2")" "$(render_factor_bool "null")" "$(render_factor_bool "$abu_ir")" "$(render_factor_bool "$abu_sc")" "$(render_factor_bool "null")" "$(render_factor_bool "null")" "$(render_factor_bool "null")" "$(render_factor_bool "null")"
            printf "${C_CYAN}移动：  ${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_bool "$mob_i2")" "$(render_factor_bool "$mob_ii")" "$(render_factor_bool "null")" "$(render_factor_bool "null")" "$(render_factor_bool "null")" "$(render_factor_bool "$mob_iq")" "$(render_factor_bool "$mob_ia")" "$(render_factor_bool "null")"
            printf "${C_CYAN}机器人：${C_RESET}%b%b%b%b%b%b%b%b\n" "$(render_factor_bool "$rob_i2")" "$(render_factor_bool "null")" "$(render_factor_bool "null")" "$(render_factor_bool "$rob_sc")" "$(render_factor_bool "null")" "$(render_factor_bool "null")" "$(render_factor_bool "null")" "$(render_factor_bool "$rob_db")"
        fi

        # 若已配置免费扩展库（ipapi.is / AbuseIPDB / ipdata / IPQS）且返回数据，自动展示对齐扩展因子表
        if [[ -f "$f_ipapi_is" || -f "$f_abuse" || -f "$f_ipdata" || -f "$f_ipqs" ]]; then
            local ex_hdr="" ex_cc="" ex_px="" ex_tor="" ex_vpn="" ex_srv="" ex_abu="" ex_mob="" ex_rob=""
            if [[ -f "$f_ipapi_is" ]]; then
                ex_hdr+="ipapi.is"; ex_cc+="$(render_factor_cc "$cc_is")"; ex_px+="$(render_factor_bool "$px_is")"; ex_tor+="$(render_factor_bool "$tor_is")"
                ex_vpn+="$(render_factor_bool "$vpn_is")"; ex_srv+="$(render_factor_bool "$srv_is")"; ex_abu+="$(render_factor_bool "$abu_is")"; ex_mob+="$(render_factor_bool "$mob_is")"; ex_rob+="$(render_factor_bool "$rob_is")"
            fi
            if [[ -f "$f_abuse" ]]; then
                ex_hdr+="AbuseIP "; ex_cc+="$(render_factor_cc "$cc_ab")"; ex_px+="$(render_factor_bool "null")"; ex_tor+="$(render_factor_bool "$tor_ab")"
                ex_vpn+="$(render_factor_bool "null")"; ex_srv+="$(render_factor_bool "null")"; ex_abu+="$(render_factor_bool "$abu_ab")"; ex_mob+="$(render_factor_bool "null")"; ex_rob+="$(render_factor_bool "null")"
            fi
            if [[ -f "$f_ipdata" ]]; then
                ex_hdr+=" ipdata "; ex_cc+="$(render_factor_cc "$cc_id")"; ex_px+="$(render_factor_bool "$px_id")"; ex_tor+="$(render_factor_bool "$tor_id")"
                ex_vpn+="$(render_factor_bool "null")"; ex_srv+="$(render_factor_bool "$srv_id")"; ex_abu+="$(render_factor_bool "$abu_id")"; ex_mob+="$(render_factor_bool "null")"; ex_rob+="$(render_factor_bool "null")"
            fi
            if [[ -f "$f_ipqs" ]]; then
                ex_hdr+="  IPQS  "; ex_cc+="$(render_factor_cc "$cc_qs")"; ex_px+="$(render_factor_bool "$px_qs")"; ex_tor+="$(render_factor_bool "$tor_qs")"
                ex_vpn+="$(render_factor_bool "$vpn_qs")"; ex_srv+="$(render_factor_bool "null")"; ex_abu+="$(render_factor_bool "$abu_qs")"; ex_mob+="$(render_factor_bool "$mob_qs")"; ex_rob+="$(render_factor_bool "$rob_qs")"
            fi
            if [[ "$LANG_CODE" == "en" ]]; then
                echo -e "${C_CYAN}ExtDB:  ${C_RESET}${C_ITALIC}${ex_hdr}${C_RESET}"
                printf "${C_CYAN}Region: ${C_RESET}%b\n" "$ex_cc"
                printf "${C_CYAN}Proxy:  ${C_RESET}%b\n" "$ex_px"
                printf "${C_CYAN}Tor:    ${C_RESET}%b\n" "$ex_tor"
                printf "${C_CYAN}VPN:    ${C_RESET}%b\n" "$ex_vpn"
                printf "${C_CYAN}Server: ${C_RESET}%b\n" "$ex_srv"
                printf "${C_CYAN}Abuser: ${C_RESET}%b\n" "$ex_abu"
                printf "${C_CYAN}Mobile: ${C_RESET}%b\n" "$ex_mob"
                printf "${C_CYAN}Robot:  ${C_RESET}%b\n" "$ex_rob"
            else
                echo -e "${C_CYAN}扩展库：${C_RESET}${C_ITALIC}${ex_hdr}${C_RESET}"
                printf "${C_CYAN}地区：  ${C_RESET}%b\n" "$ex_cc"
                printf "${C_CYAN}代理：  ${C_RESET}%b\n" "$ex_px"
                printf "${C_CYAN}Tor：   ${C_RESET}%b\n" "$ex_tor"
                printf "${C_CYAN}VPN：   ${C_RESET}%b\n" "$ex_vpn"
                printf "${C_CYAN}服务器：${C_RESET}%b\n" "$ex_srv"
                printf "${C_CYAN}滥用：  ${C_RESET}%b\n" "$ex_abu"
                printf "${C_CYAN}移动：  ${C_RESET}%b\n" "$ex_mob"
                printf "${C_CYAN}机器人：${C_RESET}%b\n" "$ex_rob"
            fi
        fi

        if (( sfs_appears > 0 )); then
            if [[ "$LANG_CODE" == "en" ]]; then
                echo -e "${C_RED}${C_BOLD}StopForumSpam Alert: Listed (frequency=${sfs_freq}, confidence=${sfs_conf}%)${C_RESET}"
            else
                echo -e "${C_RED}${C_BOLD}StopForumSpam 告警：已收录垃圾/滥用源 (频次: ${sfs_freq}, 置信度: ${sfs_conf}%)${C_RESET}"
            fi
        fi

        local missing_keys=""
        [[ -z "${IPAPI_IS_API_KEY:-}" ]]  && missing_keys="${missing_keys}${missing_keys:+/}ipapi.is"
        [[ -z "${ABUSEIPDB_API_KEY:-}" ]] && missing_keys="${missing_keys}${missing_keys:+/}AbuseIPDB"
        [[ -z "${IPDATA_API_KEY:-}" ]]    && missing_keys="${missing_keys}${missing_keys:+/}ipdata"
        [[ -z "${IPQS_API_KEY:-}" ]]      && missing_keys="${missing_keys}${missing_keys:+/}IPQS"
        if [[ -n "$missing_keys" ]]; then
            if [[ "$LANG_CODE" == "en" ]]; then
                echo -e "${C_DIM}Tip: Run --keys to add free API keys for ${missing_keys}${C_RESET}"
            else
                echo -e "${C_DIM}提示：运行 --keys 可配置免费自有 Key 一键启用 ${missing_keys} 扩展库${C_RESET}"
            fi
        fi

        # 五、流媒体及AI服务解锁检测（经典 8 列横向色块矩阵）
        if [[ "$SKIP_MEDIA" -eq 0 ]]; then
            if [[ "$LANG_CODE" == "en" ]]; then
                echo -e "5. Accessibility Check for AI and Streaming Services"
                echo -e "${C_CYAN}Service:${C_RESET}${C_ITALIC}ChatGPT Claude  Gemini  Netflix Disney+ YouTube TikTok  PrimeV  Reddit  ${C_RESET}"
                printf "${C_CYAN}Status: ${C_RESET}%b%b%b%b%b%b%b%b%b\n" \
                    "$(render_media_badge_8 "$m_chatgpt_s")" "$(render_media_badge_8 "$m_claude_s")" "$(render_media_badge_8 "$m_gemini_s")" \
                    "$(render_media_badge_8 "$m_netflix_s")" "$(render_media_badge_8 "$m_disney_s")" "$(render_media_badge_8 "$m_youtube_s")" \
                    "$(render_media_badge_8 "$m_tiktok_s")" "$(render_media_badge_8 "$m_prime_s")" "$(render_media_badge_8 "$m_reddit_s")"
                printf "${C_CYAN}Region: ${C_RESET}%b%b%b%b%b%b%b%b%b\n" \
                    "$(render_media_region_8 "$m_chatgpt_s" "$m_chatgpt_r")" "$(render_media_region_8 "$m_claude_s" "$m_claude_r")" "$(render_media_region_8 "$m_gemini_s" "$m_gemini_r")" \
                    "$(render_media_region_8 "$m_netflix_s" "$m_netflix_r")" "$(render_media_region_8 "$m_disney_s" "$m_disney_r")" "$(render_media_region_8 "$m_youtube_s" "$m_youtube_r")" \
                    "$(render_media_region_8 "$m_tiktok_s" "$m_tiktok_r")" "$(render_media_region_8 "$m_prime_s" "$m_prime_r")" "$(render_media_region_8 "$m_reddit_s" "$m_reddit_r")"
            else
                echo -e "五、流媒体及AI服务解锁检测"
                echo -e "${C_CYAN}服务：  ${C_RESET}${C_ITALIC}ChatGPT Claude  Gemini  Netflix Disney+ YouTube TikTok  PrimeV  Reddit  ${C_RESET}"
                printf "${C_CYAN}状态：  ${C_RESET}%b%b%b%b%b%b%b%b%b\n" \
                    "$(render_media_badge_8 "$m_chatgpt_s")" "$(render_media_badge_8 "$m_claude_s")" "$(render_media_badge_8 "$m_gemini_s")" \
                    "$(render_media_badge_8 "$m_netflix_s")" "$(render_media_badge_8 "$m_disney_s")" "$(render_media_badge_8 "$m_youtube_s")" \
                    "$(render_media_badge_8 "$m_tiktok_s")" "$(render_media_badge_8 "$m_prime_s")" "$(render_media_badge_8 "$m_reddit_s")"
                printf "${C_CYAN}地区：  ${C_RESET}%b%b%b%b%b%b%b%b%b\n" \
                    "$(render_media_region_8 "$m_chatgpt_s" "$m_chatgpt_r")" "$(render_media_region_8 "$m_claude_s" "$m_claude_r")" "$(render_media_region_8 "$m_gemini_s" "$m_gemini_r")" \
                    "$(render_media_region_8 "$m_netflix_s" "$m_netflix_r")" "$(render_media_region_8 "$m_disney_s" "$m_disney_r")" "$(render_media_region_8 "$m_youtube_s" "$m_youtube_r")" \
                    "$(render_media_region_8 "$m_tiktok_s" "$m_tiktok_r")" "$(render_media_region_8 "$m_prime_s" "$m_prime_r")" "$(render_media_region_8 "$m_reddit_s" "$m_reddit_r")"
            fi
        fi

        # 六、邮局连通性及黑名单检测
        local mail_badges=""
        [[ -n "$mail_ok_list" || -n "$mail_fail_list" ]] && mail_badges=$(render_mail_badges "$mail_ok_list" "$mail_fail_list")
        if [[ "$LANG_CODE" == "en" ]]; then
            echo -e "6. Email Service Availability and Blacklist Detection"
            case "$mail_local" in
                available)    echo -e "${C_CYAN}Local Port 25 Outbound: ${C_GREEN}Available${C_RESET}" ;;
                occupied)     echo -e "${C_CYAN}Local Port 25 Outbound: ${C_YELLOW}Occupied${C_RESET}" ;;
                proxy_skip)   echo -e "${C_CYAN}Local Port 25 Outbound: ${C_DIM}Skipped in proxy mode (prevents direct IP leak)${C_RESET}" ;;
                default_skip) echo -e "${C_CYAN}Local Port 25 Outbound: ${C_DIM}Skipped by default (use --mail to probe)${C_RESET}" ;;
                user_skip)    echo -e "${C_CYAN}Local Port 25 Outbound: ${C_DIM}Skipped (--no-mail)${C_RESET}" ;;
                no_nc)        echo -e "${C_CYAN}Local Port 25 Outbound: ${C_DIM}Skipped (nc not installed)${C_RESET}" ;;
                *)            echo -e "${C_CYAN}Local Port 25 Outbound: ${C_RED}Blocked${C_RESET}" ;;
            esac
            if [[ -n "$mail_badges" ]]; then
                echo -e "${C_CYAN}Conn: ${C_RESET}${mail_badges}"
            fi
            if [[ "$stack" == "4" ]]; then
                echo -e "${C_CYAN}DNSBL database (${dnsbl_mode}):  ${C_CYAN}Active ${C_BOLD}${dnsbl_total}${C_RESET}   ${C_GREEN}Clean ${C_BOLD}${dnsbl_clean}${C_RESET}   ${C_RED}Blacklisted ${C_BOLD}${dnsbl_hits}${C_RESET}"
                [[ -n "$dnsbl_hit_names" ]] && echo -e "${C_RED}${C_BOLD}Blacklisted By: ${C_RESET}${dnsbl_hit_names}"
            else
                echo -e "${C_CYAN}DNSBL database: ${C_DIM}IPv4 only (skipped for IPv6)${C_RESET}"
            fi
            echo -e "${eq_line}"
            echo -e "${C_ITALIC}IPzhiliang v${VERSION} · 100% Standalone · Zero-Upload Privacy Mode${C_RESET}"
        else
            echo -e "六、邮局连通性及黑名单检测"
            case "$mail_local" in
                available)    echo -e "${C_CYAN}本地25端口出站：${C_GREEN}可用${C_RESET}" ;;
                occupied)     echo -e "${C_CYAN}本地25端口出站：${C_YELLOW}占用${C_RESET}" ;;
                proxy_skip)   echo -e "${C_CYAN}本地25端口出站：${C_DIM}代理模式已跳过（防止直连泄露宿主机IP）${C_RESET}" ;;
                default_skip) echo -e "${C_CYAN}本地25端口出站：${C_DIM}默认跳过（防云商25端口风控断连，加 --mail 开启）${C_RESET}" ;;
                user_skip)    echo -e "${C_CYAN}本地25端口出站：${C_DIM}已跳过 (--no-mail)${C_RESET}" ;;
                no_nc)        echo -e "${C_CYAN}本地25端口出站：${C_DIM}未安装 nc 已跳过${C_RESET}" ;;
                *)            echo -e "${C_CYAN}本地25端口出站：${C_RED}阻断${C_RESET}" ;;
            esac
            if [[ -n "$mail_badges" ]]; then
                echo -e "${C_CYAN}通信：${C_RESET}${mail_badges}"
            fi
            if [[ "$stack" == "4" ]]; then
                echo -e "${C_CYAN}IP地址黑名单数据库 (${dnsbl_mode})：  ${C_CYAN}有效 ${C_BOLD}${dnsbl_total}${C_RESET}   ${C_GREEN}正常 ${C_BOLD}${dnsbl_clean}${C_RESET}   ${C_RED}黑名单 ${C_BOLD}${dnsbl_hits}${C_RESET}"
                [[ -n "$dnsbl_hit_names" ]] && echo -e "${C_RED}${C_BOLD}命中黑名单：${C_RESET}${dnsbl_hit_names}"
            else
                echo -e "${C_CYAN}IP地址黑名单数据库：${C_DIM}仅支持 IPv4（IPv6 自动跳过）${C_RESET}"
            fi
            echo -e "${eq_line}"
            echo -e "${C_ITALIC}IPzhiliang v${VERSION} · 独立自研引擎 · 零中转 · 纯本地零上传${C_RESET}"
        fi
        echo ""
    } > "$report_ansi_file"

    # 终端输出
    if [[ "$JSON_MODE" -eq 1 ]]; then
        echo "$report_json"
    else
        cat "$report_ansi_file"
    fi

    # 导出到本地文件（0600 权限）
    if [[ -n "$out_path" ]]; then
        case "$out_path" in
            *.[aA][nN][sS][iI])
                cat "$report_ansi_file" >> "$out_path"
                ;;
            *.[jJ][sS][oO][nN])
                printf '%s\n' "$report_json" >> "$out_path"
                ;;
            *)
                strip_ansi < "$report_ansi_file" >> "$out_path"
                ;;
        esac
        chmod 600 "$out_path" 2>/dev/null || true
    fi
}

# ==============================================================================
# 任务调度：支持整机 / 多端口批量 / 指定网卡或出口 IP
# ==============================================================================

derive_output_path() {
    local base_path="$1"
    local idx="$2"
    local total="$3"
    if [[ -z "$base_path" || "$total" -le 1 ]]; then
        echo "$base_path"
        return
    fi
    local ext=""
    local stem="$base_path"
    if [[ "$base_path" == *.* ]]; then
        ext=".${base_path##*.}"
        stem="${base_path%.*}"
    fi
    echo "${stem}_${idx}${ext}"
}

prepare_output_file() {
    local out_path="$1"
    [[ -z "$out_path" ]] && return 0
    local old_umask
    old_umask=$(umask)
    umask 077
    : > "$out_path"
    chmod 600 "$out_path" 2>/dev/null || true
    umask "$old_umask"
}

run_target_egress() {
    local out_path="$1"
    local ip4="" ip6="" ran_any=0

    if [[ "$IP_STACK" == "both" || "$IP_STACK" == "4" ]]; then
        if ip4=$(fetch_egress_ipv4); then
            run_single_ip_check "$ip4" "4" "$out_path"
            ran_any=1
        elif [[ "$IP_STACK" == "4" ]]; then
            echo -e "${C_RED}[错误] 无法获取 IPv4 出口地址，请检查网络或代理/网卡设置。${C_RESET}" >&2
            return 1
        fi
    fi

    if [[ "$IP_STACK" == "both" || "$IP_STACK" == "6" ]]; then
        if ip6=$(fetch_egress_ipv6); then
            run_single_ip_check "$ip6" "6" "$out_path"
            ran_any=1
        elif [[ "$IP_STACK" == "6" ]]; then
            echo -e "${C_RED}[错误] 无法获取 IPv6 出口地址，请检查网络或代理/网卡设置。${C_RESET}" >&2
            return 1
        fi
    fi

    if [[ $ran_any -eq 0 ]]; then
        echo -e "${C_RED}[错误] IPv4 与 IPv6 出口均不可达，请检查网络连接或目标配置。${C_RESET}" >&2
        return 1
    fi

    if [[ -n "$out_path" && -f "$out_path" ]]; then
        echo -e "${C_GREEN}[已保存] 报告已写入 ${out_path} (权限 0600)${C_RESET}" >&2
    fi
    return 0
}

execute_checks() {
    align_iface_ip_stack
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo -e "${C_YELLOW}[Dry-Run] 预览模式，未发起实际网络检测。${C_RESET}"
        if [[ "$TARGET_MODE" == "port" ]]; then
            local i=1 total=${#TARGET_PORTS[@]} p out_path
            for p in "${TARGET_PORTS[@]}"; do
                out_path=$(derive_output_path "$OUTPUT_FILE" "$i" "$total")
                echo "  [$i/$total] 独立引擎检测代理: $(mask_proxy_url "$p")  (协议栈: ${IP_STACK}, 隐私模式: ${PRIVACY_MODE}${out_path:+, 导出: ${out_path}})"
                i=$((i + 1))
            done
        elif [[ "$TARGET_MODE" == "iface" ]]; then
            echo "  独立引擎检测出口: $(format_iface_display "$TARGET_IFACE")  (协议栈: ${IP_STACK}, 隐私模式: ${PRIVACY_MODE}${OUTPUT_FILE:+, 导出: ${OUTPUT_FILE}})"
        else
            echo "  独立引擎检测本机默认出口  (协议栈: ${IP_STACK}, 隐私模式: ${PRIVACY_MODE}${OUTPUT_FILE:+, 导出: ${OUTPUT_FILE}})"
        fi
        return 0
    fi

    TMP_WORKDIR=$(make_temp_dir "ipzhiliang_work")

    if [[ "$TARGET_MODE" == "port" ]]; then
        TMP_CURL_CFG=$(make_temp_file "ipzhiliang_curl")
        local i=1 total=${#TARGET_PORTS[@]} p out_path
        for p in "${TARGET_PORTS[@]}"; do
            out_path=$(derive_output_path "$OUTPUT_FILE" "$i" "$total")
            prepare_output_file "$out_path"
            printf 'proxy = "%s"\n' "$p" > "$TMP_CURL_CFG"
            chmod 600 "$TMP_CURL_CFG" 2>/dev/null || true
            ACTIVE_CURL_CFG="$TMP_CURL_CFG"
            ACTIVE_IFACE=""
            ACTIVE_PROXY_DISPLAY=$(mask_proxy_url "$p")
            echo ""
            echo -e "${C_BOLD}${C_GREEN}>>> [${i}/${total}] 正在独立检测代理出口: ${ACTIVE_PROXY_DISPLAY}${C_RESET}" >&2
            run_target_egress "$out_path" || true
            i=$((i + 1))
        done
    elif [[ "$TARGET_MODE" == "iface" ]]; then
        prepare_output_file "$OUTPUT_FILE"
        ACTIVE_CURL_CFG=""
        ACTIVE_IFACE="$TARGET_IFACE"
        ACTIVE_PROXY_DISPLAY=""
        echo ""
        echo -e "${C_BOLD}${C_GREEN}>>> 正在独立检测指定出口: $(format_iface_display "$TARGET_IFACE")${C_RESET}" >&2
        run_target_egress "$OUTPUT_FILE"
    else
        prepare_output_file "$OUTPUT_FILE"
        ACTIVE_CURL_CFG=""
        ACTIVE_IFACE=""
        ACTIVE_PROXY_DISPLAY=""
        echo ""
        echo -e "${C_BOLD}${C_GREEN}>>> 正在启动独立 IP 质量体检...${C_RESET}" >&2
        run_target_egress "$OUTPUT_FILE"
    fi
}

# ==============================================================================
# CLI 参数解析与交互主循环
# ==============================================================================

require_opt_arg() {
    local opt_name="$1"
    local arg_count="$2"
    local opt_val="${3:-}"
    if (( arg_count < 2 )) || [[ -z "$opt_val" || "$opt_val" == -* ]]; then
        echo -e "${C_RED}[错误] 参数 ${opt_name} 需要提供一个有效值。${C_RESET}"
        echo "使用 --help 查看帮助。"
        exit 1
    fi
}

parse_cli_args() {
    local cli_full=0 cli_ports=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)
                require_opt_arg "$1" "$#" "${2:-}"
                NON_INTERACTIVE=1
                TARGET_MODE="port"
                cli_ports="$2"
                shift 2
                ;;
            --port=*)
                NON_INTERACTIVE=1
                TARGET_MODE="port"
                cli_ports="${1#*=}"
                [[ -z "$cli_ports" ]] && require_opt_arg "--port" 1 ""
                shift
                ;;
            --iface)
                require_opt_arg "$1" "$#" "${2:-}"
                NON_INTERACTIVE=1
                TARGET_MODE="iface"
                TARGET_IFACE="${2%%/*}"
                shift 2
                ;;
            --iface=*)
                NON_INTERACTIVE=1
                TARGET_MODE="iface"
                TARGET_IFACE="${1#*=}"
                TARGET_IFACE="${TARGET_IFACE%%/*}"
                [[ -z "$TARGET_IFACE" ]] && require_opt_arg "--iface" 1 ""
                shift
                ;;
            --privacy)
                NON_INTERACTIVE=1
                PRIVACY_MODE="1"
                shift
                ;;
            --public)
                NON_INTERACTIVE=1
                echo -e "${C_YELLOW}[提示] IPzhiliang v2 已全面独立并彻底移除第三方报告上传，自动以纯本地隐私打码模式运行。${C_RESET}" >&2
                PRIVACY_MODE="1"
                shift
                ;;
            --full|-f)
                NON_INTERACTIVE=1
                cli_full=1
                shift
                ;;
            -4)
                NON_INTERACTIVE=1
                IP_STACK="4"
                shift
                ;;
            -6)
                NON_INTERACTIVE=1
                IP_STACK="6"
                shift
                ;;
            -l)
                require_opt_arg "$1" "$#" "${2:-}"
                NON_INTERACTIVE=1
                if ! LANG_CODE=$(normalize_lang_code "$2"); then
                    echo -e "${C_RED}[错误] 不支持的语言代码: $2 (可选: cn | en)${C_RESET}"
                    exit 1
                fi
                shift 2
                ;;
            -l=*)
                NON_INTERACTIVE=1
                if ! LANG_CODE=$(normalize_lang_code "${1#*=}"); then
                    echo -e "${C_RED}[错误] 不支持的语言代码: ${1#*=} (可选: cn | en)${C_RESET}"
                    exit 1
                fi
                shift
                ;;
            -E)
                NON_INTERACTIVE=1
                LANG_CODE="en"
                shift
                ;;
            -o)
                require_opt_arg "$1" "$#" "${2:-}"
                NON_INTERACTIVE=1
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -o=*)
                NON_INTERACTIVE=1
                OUTPUT_FILE="${1#*=}"
                [[ -z "$OUTPUT_FILE" ]] && require_opt_arg "-o" 1 ""
                shift
                ;;
            -j)
                NON_INTERACTIVE=1
                JSON_MODE=1
                shift
                ;;
            --no-media)
                NON_INTERACTIVE=1
                SKIP_MEDIA=1
                shift
                ;;
            --mail)
                NON_INTERACTIVE=1
                MAIL_MODE="enable"
                shift
                ;;
            --no-mail)
                NON_INTERACTIVE=1
                MAIL_MODE="skip_user"
                shift
                ;;
            -y)
                DEP_MODE="auto"
                shift
                ;;
            -n)
                DEP_MODE="skip"
                shift
                ;;
            --update)
                self_update
                ;;
            --keys)
                configure_api_keys_interactive
                exit 0
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                echo -e "${C_RED}[错误] 未知参数: $1${C_RESET}"
                echo "使用 --help 查看帮助。"
                exit 1
                ;;
        esac
    done

    if [[ "$cli_full" -eq 1 ]]; then
        PRIVACY_MODE="2"
    else
        PRIVACY_MODE="1"
    fi

    if [[ "$TARGET_MODE" == "port" ]]; then
        if [[ -z "$cli_ports" ]]; then
            echo -e "${C_RED}[错误] --port 需要提供端口号或代理地址。${C_RESET}"
            exit 1
        fi
        local IFS=','
        local items=($cli_ports)
        local item resolved rc norm_item
        for item in "${items[@]}"; do
            [[ -z "$item" ]] && continue
            if [[ "$DRY_RUN" -eq 1 ]]; then
                norm_item=$(normalize_proxy_auth "$item")
                if [[ "$norm_item" =~ ^(socks5h?|socks4a?|https?):// ]]; then
                    TARGET_PORTS+=("$norm_item")
                elif [[ "$norm_item" =~ ^[0-9]+$ ]]; then
                    if (( 10#$norm_item < 1 || 10#$norm_item > 65535 )); then
                        echo -e "${C_RED}[错误] 端口号必须在 1-65535 之间: $norm_item${C_RESET}" >&2
                        exit 1
                    fi
                    TARGET_PORTS+=("socks5h://127.0.0.1:${norm_item}")
                else
                    TARGET_PORTS+=("socks5h://${norm_item}")
                fi
            else
                resolved=$(resolve_port_to_proxy "$item")
                rc=$?
                if [[ $rc -eq 0 || $rc -eq 2 ]]; then
                    TARGET_PORTS+=("$resolved")
                else
                    exit 1
                fi
            fi
        done
    fi
}

interactive_loop() {
    while true; do
        step_select_target
        step_select_privacy
        step_select_ip_stack

        while true; do
            show_summary
            echo ""
            echo -e "操作: ${C_GREEN}[Enter]${C_RESET} 开始检测  |  ${C_PURPLE}[a]${C_RESET} 高级选项(语言/导出/Key)  |  ${C_YELLOW}[r]${C_RESET} 重新配置  |  ${C_RED}[q]${C_RESET} 退出"
            local action=""
            tty_read "请选择: " action
            case "$action" in
                "")
                    execute_checks
                    return 0
                    ;;
                a|A)
                    step_advanced_options
                    ;;
                r|R)
                    echo ""
                    break
                    ;;
                q|Q)
                    echo -e "${C_YELLOW}已退出。${C_RESET}"
                    exit 0
                    ;;
                *)
                    echo -e "${C_YELLOW}请输入 Enter / a / r / q${C_RESET}"
                    ;;
            esac
        done
    done
}

main() {
    load_saved_keys
    parse_cli_args "$@"
    check_env
    if [[ "$JSON_MODE" -eq 0 ]]; then
        print_banner
    fi
    check_self_update "$@"

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        [[ "$JSON_MODE" -eq 0 ]] && show_summary
        execute_checks
    else
        interactive_loop
    fi
}

main "$@"

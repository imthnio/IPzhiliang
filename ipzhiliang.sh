#!/usr/bin/env bash
# ==============================================================================
# IPzhiliang - IP 质量交互式一键检测脚本
# GitHub: https://github.com/imthnio/IPzhiliang
# 上游核心检测引擎: https://github.com/xykt/IPQuality (https://IP.Check.Place)
# ==============================================================================

set -u

VERSION="1.3.0"
SELF_RAW_URL="https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh"
UPSTREAM_PRIMARY="https://IP.Check.Place"
UPSTREAM_FALLBACK="https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh"

# 颜色定义
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_RED="\033[31m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_BLUE="\033[34m"
C_PURPLE="\033[35m"
C_CYAN="\033[36m"

# 运行配置状态
TARGET_MODE="machine"      # machine | port | iface
TARGET_PORTS=()            # 单个或多个端口/代理 URL
TARGET_IFACE=""            # 网卡名或出口 IP
PRIVACY_MODE="1"           # 1:隐私隐藏(-p) 2:公开隐藏 3:公开完整(-f) 4:本地完整(-p -f)
IP_STACK="both"            # both | 4 | 6
LANG_CODE="cn"             # cn | en | jp | es | de | fr | ru | pt
OUTPUT_FILE=""             # 导出文件路径
JSON_MODE=0                # -j
DEP_MODE="auto"            # default | auto(-y) | skip(-n)
DRY_RUN=0                  # 仅展示命令不执行
NON_INTERACTIVE=0          # CLI 直通模式

TMP_SCRIPT=""
TMP_CURL_CFG=""

cleanup() {
    if [[ -n "$TMP_CURL_CFG" && -f "$TMP_CURL_CFG" ]]; then
        rm -f "$TMP_CURL_CFG"
    fi
    if [[ -n "$TMP_SCRIPT" && -f "$TMP_SCRIPT" ]]; then
        rm -f "$TMP_SCRIPT" "${TMP_SCRIPT}.patched"
    fi
}
trap cleanup EXIT
trap 'cleanup; echo -e "\n${C_YELLOW}已取消检测。${C_RESET}"; exit 130' INT TERM

# 检测当前进程是否拥有真正可打开的控制终端（修复无 TTY 会话下 [ -r /dev/tty ] 误判为真导致崩溃的问题）
has_controlling_tty() {
    (: </dev/tty) 2>/dev/null
}

# 兼容 `bash <(curl ...)` 和 `curl ... | bash` 的安全读取函数
# 注意：内部变量使用 __tty_ 前缀，避免与调用方传入的变量名冲突；处理 EOF 防止死循环
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

# 自动识别当前操作系统与虚拟化环境（母鸡/小鸡）
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

    if [[ -f /.dockerenv ]] || grep -qaE 'docker|containerd' /proc/1/cgroup 2>/dev/null; then
        virt_type="Docker容器(小鸡)"
    elif [[ -f /proc/user_beancounters ]] || [[ -d /proc/vz ]]; then
        virt_type="OpenVZ(小鸡)"
    elif grep -qaE 'lxc|kubepods' /proc/1/cgroup 2>/dev/null || [[ "${container:-}" == "lxc" ]]; then
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

print_banner() {
    local host_env
    host_env=$(detect_host_env)
    echo -e "${C_CYAN}${C_BOLD}"
    echo "================================================================"
    echo "              IPzhiliang · IP 质量一键交互检测工具"
    echo "================================================================"
    echo -e "${C_RESET}${C_DIM} 版本: v${VERSION}  |  核心引擎: xykt/IPQuality (IP.Check.Place)${C_RESET}"
    echo -e "${C_DIM} 环境: ${host_env}${C_RESET}"
    echo -e "${C_DIM} 仓库: https://github.com/imthnio/IPzhiliang${C_RESET}"
    echo ""
}

print_usage() {
    cat <<EOF
IPzhiliang v${VERSION} - IP 质量交互式一键检测脚本

用法:
  交互式运行 (推荐):
    bash <(curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh)

  命令行直通运行:
    bash ipzhiliang.sh [选项]

选项:
  --port <目标>      检测指定端口/代理出口 (支持 21233 / 127.0.0.1:21233 / socks5://... / 多端口逗号分隔)
  --iface <网卡/IP>  检测指定出口网卡或出口 IP (如 eth0 / warp / 1.2.3.4)
  --privacy          隐私保护模式：隐藏 IP 且不生成公开报告链接 (-p) [默认]
  --public           公开分享模式：隐藏 IP 并生成公开报告链接
  --full             展示完整 IP 地址 (-f)，可与 --privacy 或 --public 组合
  -4                 仅检测 IPv4
  -6                 仅检测 IPv6
  -l <语言>          报告语言: cn | en | jp | es | de | fr | ru | pt (默认 cn)
  -E                 英文报告 (等同于 -l en)
  -o <路径>          将报告保存到本地文件 (.txt / .ansi / .json，自动设置 0600 隐私权限)
  -j                 以 JSON 格式输出
  -y                 自动安装缺失依赖 [默认]
  -n                 跳过系统与依赖检测
  --update           将本地 ipzhiliang.sh 更新到 GitHub 最新版本
  --dry-run          仅打印最终将执行的命令，不实际运行检测
  -h, --help         显示本帮助信息
EOF
}

# 兼容 GNU / BusyBox(Alpine) / macOS 的安全临时文件创建函数（强制 0600 权限防同机其他用户窥探）
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

# 判断当前脚本是否属于远程流或 run.sh 引导的临时文件
is_ephemeral_script_path() {
    local p="${1:-}"
    if [[ -z "$p" || ! -f "$p" || "$p" == /dev/fd/* || "$p" == /proc/self/fd/* || "$p" == */ipzhiliang_main.* || "${IPZHILIANG_BOOTSTRAPPED:-0}" == "1" ]]; then
        return 0
    fi
    return 1
}

# 本地脚本自更新
self_update() {
    local target_path="${BASH_SOURCE[0]:-}"
    if is_ephemeral_script_path "$target_path"; then
        echo -e "${C_GREEN}[提示] 你正在通过远程一键命令运行，每次执行已自动拉取最新版脚本与检测数据库。${C_RESET}"
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

# 若以本地文件方式运行，全自动检查并直接静默更新到最新版本（2秒超时，不阻塞，带防递归死循环保护）
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
                exec "${BASH4_BIN:-${BASH:-bash}}" "$target_path" "$@"
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

# 查找可用的 Bash >= 4.0（上游 IP.Check.Place 要求 Bash 4+）
find_bash4() {
    local candidates=("${BASH:-/bin/bash}" "/opt/homebrew/bin/bash" "/usr/local/bin/bash" "/usr/bin/bash" "/bin/bash")
    local b ver
    for b in "${candidates[@]}"; do
        if [[ -x "$b" ]]; then
            ver=$("$b" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 0)
            if [[ "$ver" =~ ^[0-9]+$ ]] && (( ver >= 4 )); then
                echo "$b"
                return 0
            fi
        fi
    done
    return 1
}

check_env() {
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${C_RED}[错误] 未检测到 curl，请先安装 curl 后重试。${C_RESET}"
        echo -e "${C_DIM}  Debian/Ubuntu: apt update && apt install -y curl${C_RESET}"
        echo -e "${C_DIM}  CentOS/RHEL:   yum install -y curl${C_RESET}"
        exit 1
    fi

    if ! BASH4_BIN=$(find_bash4); then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            BASH4_BIN="${BASH:-/bin/bash}"
            echo -e "${C_YELLOW}[提示] 当前环境未检测到 Bash 4.0+（Dry-Run 模式继续预览；实际运行需 Bash 4.0+）。${C_RESET}"
        else
            echo -e "${C_RED}[错误] 上游检测引擎需要 Bash 4.0 及以上版本。${C_RESET}"
            echo -e "${C_YELLOW}提示：${C_RESET}"
            echo "  macOS 可运行: brew install bash"
            echo "  Linux 可运行: bash <(curl -sL https://raw.githubusercontent.com/xykt/IPQuality/main/ref/upgrade_bash.sh)"
            exit 1
        fi
    fi
}

# 判断字符串是否为合法 IPv4 字面量
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

# 判断字符串是否为合法 IPv6 字面量
is_ipv6_literal() {
    local ip="${1%%/*}"
    ip="${ip%%%*}"
    [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:.]+$ ]]
}

# 判断字符串是否为合法 IPv4 或 IPv6 地址
is_valid_ip_literal() {
    is_ipv4_literal "$1" || is_ipv6_literal "$1"
}

# 判断是否为本地回环地址
is_loopback_host() {
    local h="${1#[}"
    h="${h%]}"
    [[ "$h" == "127."* || "$h" == "localhost" || "$h" == "::1" || "$h" == "0.0.0.0" || "$h" == "::" || "$h" == "*" ]]
}

# 对代理用户名或密码进行安全 URL 编码（保留已有的 %XX 转义，防止密码含 @ : / # ? 等特殊字符导致 curl 报错）
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

# 规范化用户直接输入的代理地址中的认证信息（若密码包含未编码的 @ 或 :，自动完成 URL 编码）
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

    # 始终按最后一个 @ 切分凭据与主机地址，防止密码本身包含 @
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

# 打码 IPv4/IPv6 用于隐私预览（保留首段与尾段，中间打码：既严防泄露完整 IP，又能清晰区分同 C 段/同前缀下的多出口 IP）
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

# 隐藏代理 URL 中的密码（以及在隐藏 IP 模式下对非本地远程代理服务器公网 IP 进行打码）
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

    # 若需要在隐私模式下隐藏远程代理主机公网 IP（保留本地 127.0.0.1 / localhost / ::1 不打码）
    if [[ "$mask_remote_host" == "1" && ( "$PRIVACY_MODE" == "1" || "$PRIVACY_MODE" == "2" ) ]]; then
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

# 对监听地址如 203.0.113.55:443 中的公网 IP 进行打码，防止端口提示列表泄露本机公网 IP
mask_listen_addr() {
    awk '{
        addr = $1
        proc = (NF > 1 ? " " $2 : "")
        # 匹配 [IPv6]:port 或 IPv4:port
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

# 检测端口是否在本机监听，并返回监听地址提示（兼容 Linux ss/netstat 与 macOS/FreeBSD lsof）
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

# 列出本机正在监听的常用本地端口（辅助用户参考，自动去重并脱敏绑定的公网 IP）
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

# 通过指定代理探测出口 IP（使用 curl -K - 从标准输入传入代理，防止 ps aux 泄露代理密码；校验返回值为合法 IP）
probe_proxy_ip() {
    local proxy_url="$1"
    local ip=""
    local endpoints=("https://api64.ipify.org" "https://myip.check.place" "https://icanhazip.com" "https://ifconfig.me/ip")
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

# 自动探测纯端口或 host:port 的代理协议 (socks5h -> http -> https)
resolve_port_to_proxy() {
    local raw
    raw=$(normalize_proxy_auth "$1")
    local auth_prefix="${2:-}"
    local hostport=""
    local probed_ip=""

    # 如果已经是完整协议 URL，直接验证连通性
    if [[ "$raw" =~ ^(socks5h?|socks4a?|https?):// ]]; then
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

    # 纯端口号 -> 补全 127.0.0.1:PORT
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
        # 校验形如 host:port 末尾的端口范围
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
    echo -e "${C_DIM}正在自动探测 ${masked_hp} 的代理协议 (SOCKS5 / HTTP / HTTPS)...${C_RESET}" >&2
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

# 交互步骤 1：选择检测目标
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
    echo "  - 纯端口号（自动探测 SOCKS5/HTTP/HTTPS）:  21233"
    echo "  - 多个端口批量检测（英文逗号分隔）:        21233,21234"
    echo "  - 主机与端口:                              127.0.0.1:21233"
    echo "  - 完整代理地址:                            socks5://user:pass@127.0.0.1:21233"
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

        # 询问是否需要账号密码（仅当输入中不含 @ 且不含 :// 时）
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

        # 解析逗号分隔的多目标
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
                # 探测失败，允许用户手动指定协议强行测试
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
            # 去掉 /CIDR 前缀，直接精准绑定到所选的具体出口 IP
            TARGET_IFACE="${raw_selected_ip%%/*}"
        else
            TARGET_IFACE="${iface_input%%/*}"
        fi
        break
    done
}

# 若 TARGET_IFACE 是具体 IPv4 或 IPv6 字面量，自动对齐 IP_STACK 防止协议栈与出口 IP 类型冲突
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

# 交互步骤 2：选择隐私与公开模式
step_select_privacy() {
    echo -e "${C_BOLD}${C_BLUE}[2/3] 请选择隐私与报告公开方式：${C_RESET}"
    echo -e "  ${C_GREEN}1)${C_RESET} 隐私保护模式：隐藏/打码 IP + 不上传生成公开报告链接 ${C_DIM}(-p) [默认推荐]${C_RESET}"
    echo -e "  ${C_GREEN}2)${C_RESET} 公开分享模式：隐藏/打码 IP + 生成可分享的公开报告链接"
    echo -e "  ${C_GREEN}3)${C_RESET} 公开完整模式：展示完整 IP + 生成可分享的公开报告链接 ${C_DIM}(-f)${C_RESET}"
    echo -e "  ${C_GREEN}4)${C_RESET} 本地完整模式：展示完整 IP + 不上传生成公开报告链接 ${C_DIM}(-p -f)${C_RESET}"
    echo ""

    local choice=""
    tty_read "请输入选项 [1-4] (默认 1): " choice
    case "${choice:-1}" in
        1|2|3|4) PRIVACY_MODE="${choice:-1}" ;;
        *)
            echo -e "${C_YELLOW}无效选项，默认使用隐私保护模式。${C_RESET}"
            PRIVACY_MODE="1"
            ;;
    esac
    echo ""
}

# 交互步骤 3：选择 IP 协议栈
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

# 校验并标准化语言代码（兼容用户输入 zh / ja / en-us 等常见写法）
normalize_lang_code() {
    local code
    code=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "$code" in
        cn|zh|zh-cn|zh_cn|chs) echo "cn" ;;
        en|en-us|en_us|eng)    echo "en" ;;
        jp|ja|ja-jp|ja_jp)     echo "jp" ;;
        es|de|fr|ru|pt)        echo "$code" ;;
        *)                     return 1 ;;
    esac
    return 0
}

# 可选高级选项菜单
step_advanced_options() {
    echo ""
    echo -e "${C_BOLD}${C_PURPLE}=== 高级选项设置 ===${C_RESET}"

    # 1. 报告语言
    echo -e "1) 报告语言 (当前: ${C_CYAN}${LANG_CODE}${C_RESET})"
    echo "   可选: cn (中文) | en (English) | jp | es | de | fr | ru | pt"
    local lang_in="" norm_lang=""
    tty_read "   请输入语言代码 (直接回车保持 ${LANG_CODE}): " lang_in
    if [[ -n "$lang_in" ]]; then
        if norm_lang=$(normalize_lang_code "$lang_in"); then
            LANG_CODE="$norm_lang"
        else
            echo -e "   ${C_YELLOW}[提示] 不支持的语言代码 '${lang_in}'，保持为 ${LANG_CODE}。${C_RESET}"
        fi
    fi

    # 2. 保存报告到本地文件
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

    # 3. 终端 JSON 输出
    echo ""
    local json_in=""
    tty_read "3) 是否在终端以纯 JSON 格式输出? [y/N] (当前: $([[ $JSON_MODE -eq 1 ]] && echo 是 || echo 否)): " json_in
    if [[ "$json_in" =~ ^[Yy]$ ]]; then
        JSON_MODE=1
    elif [[ "$json_in" =~ ^[Nn]$ ]]; then
        JSON_MODE=0
    fi

    # 4. 依赖处理策略
    echo ""
    echo -e "4) 缺失依赖处理方式 (当前: ${C_CYAN}${DEP_MODE}${C_RESET})"
    echo "   1) 自动安装缺失依赖 (-y，推荐不中断)"
    echo "   2) 跳过系统与依赖检测 (-n，适合已装全依赖的极速运行)"
    echo "   3) 交给上游脚本默认交互"
    local dep_in=""
    tty_read "   请选择 [1-3] (直接回车保持不变): " dep_in
    case "$dep_in" in
        1) DEP_MODE="auto" ;;
        2) DEP_MODE="skip" ;;
        3) DEP_MODE="default" ;;
    esac
    echo ""
}

# 根据当前状态拼装上游 IP.Check.Place 参数数组（针对单个代理/目标）
build_upstream_args() {
    local proxy_override="${1:-}"
    local output_override="${2:-}"
    UPSTREAM_ARGS=()

    # IP 协议栈（必须置于 -i / -x 之前，确保 get_opts 先设置 IPV4check/IPV6check）
    [[ "$IP_STACK" == "4" ]] && UPSTREAM_ARGS+=("-4")
    [[ "$IP_STACK" == "6" ]] && UPSTREAM_ARGS+=("-6")

    # 隐私与公开设置
    case "$PRIVACY_MODE" in
        1) UPSTREAM_ARGS+=("-p") ;;
        2) ;; # 默认：打码 IP + 公开报告链接
        3) UPSTREAM_ARGS+=("-f") ;;
        4) UPSTREAM_ARGS+=("-p" "-f") ;;
    esac

    # 检测目标
    if [[ "$TARGET_MODE" == "port" && -n "$proxy_override" ]]; then
        UPSTREAM_ARGS+=("-x" "$proxy_override")
    elif [[ "$TARGET_MODE" == "iface" && -n "$TARGET_IFACE" ]]; then
        UPSTREAM_ARGS+=("-i" "$TARGET_IFACE")
    fi

    # 语言
    if [[ "$LANG_CODE" == "en" ]]; then
        UPSTREAM_ARGS+=("-E")
    elif [[ -n "$LANG_CODE" && "$LANG_CODE" != "cn" ]]; then
        UPSTREAM_ARGS+=("-l" "$LANG_CODE")
    fi

    # 导出文件
    if [[ -n "$output_override" ]]; then
        UPSTREAM_ARGS+=("-o" "$output_override")
    fi

    # JSON 输出
    [[ "$JSON_MODE" -eq 1 ]] && UPSTREAM_ARGS+=("-j")

    # 依赖策略
    [[ "$DEP_MODE" == "auto" ]] && UPSTREAM_ARGS+=("-y")
    [[ "$DEP_MODE" == "skip" ]] && UPSTREAM_ARGS+=("-n")
}

# 根据当前隐私模式格式化网卡/出口 IP 用于屏幕显示
format_iface_display() {
    local val="$1"
    if [[ ( "$PRIVACY_MODE" == "1" || "$PRIVACY_MODE" == "2" ) ]] && is_valid_ip_literal "$val"; then
        mask_ip "$val"
    else
        echo "$val"
    fi
}

# 生成安全脱敏后的命令预览字符串
format_preview_cmd() {
    local preview="bash <(curl -Ls https://IP.Check.Place)"
    local next_type=""
    local arg
    for arg in "${UPSTREAM_ARGS[@]}"; do
        if [[ "$next_type" == "proxy" ]]; then
            preview+=" '$(mask_proxy_url "$arg")'"
            next_type=""
            continue
        elif [[ "$next_type" == "iface" ]]; then
            preview+=" '$(format_iface_display "$arg")'"
            next_type=""
            continue
        elif [[ "$next_type" == "out" ]]; then
            preview+=" '$arg'"
            next_type=""
            continue
        fi
        case "$arg" in
            -x)
                preview+=" -x"
                next_type="proxy"
                ;;
            -i)
                preview+=" -i"
                next_type="iface"
                ;;
            -o)
                preview+=" -o"
                next_type="out"
                ;;
            *)
                preview+=" $arg"
                ;;
        esac
    done
    echo "$preview"
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

    case "$PRIVACY_MODE" in
        1) echo -e "  隐私模式: ${C_GREEN}隐私保护 (隐藏 IP + 不上传公开报告)${C_RESET}" ;;
        2) echo -e "  隐私模式: ${C_YELLOW}公开分享 (隐藏 IP + 生成公开报告链接)${C_RESET}" ;;
        3) echo -e "  隐私模式: ${C_YELLOW}公开完整 (显示完整 IP + 生成公开报告链接)${C_RESET}" ;;
        4) echo -e "  隐私模式: ${C_GREEN}本地完整 (显示完整 IP + 不上传公开报告)${C_RESET}" ;;
    esac

    local stack_label="双栈 (IPv4 + IPv6)"
    [[ "$IP_STACK" == "4" ]] && stack_label="仅 IPv4"
    [[ "$IP_STACK" == "6" ]] && stack_label="仅 IPv6"
    echo -e "  协议版本: ${stack_label}"
    echo -e "  报告语言: ${LANG_CODE}"
    [[ -n "$OUTPUT_FILE" ]] && echo -e "  导出文件: ${OUTPUT_FILE}"
    [[ "$JSON_MODE" -eq 1 ]] && echo -e "  JSON输出: 开启"
    echo -e "  依赖策略: ${DEP_MODE}"

    # 展示等价命令
    if [[ "$TARGET_MODE" == "port" ]]; then
        build_upstream_args "${TARGET_PORTS[0]}" "$OUTPUT_FILE"
    else
        build_upstream_args "" "$OUTPUT_FILE"
    fi
    echo -e "  等价命令: ${C_DIM}$(format_preview_cmd)${C_RESET}"
    if [[ "$TARGET_MODE" == "port" && ${#TARGET_PORTS[@]} -gt 1 ]]; then
        echo -e "            ${C_DIM}(共 ${#TARGET_PORTS[@]} 个端口将依次自动检测)${C_RESET}"
    fi
    echo -e "${C_BOLD}${C_CYAN}==========================================================${C_RESET}"
}

# 对拉取到的上游脚本实施隐私加固与缺陷修复（语法校验通过后生效，100% 向后兼容）
patch_upstream_script() {
    local script_file="$1"
    local patched_file="${script_file}.patched"
    local no_upload="0"
    [[ "$PRIVACY_MODE" == "1" || "$PRIVACY_MODE" == "4" ]] && no_upload="1"

    awk -v privacy_no_upload="$no_upload" '
    # 1. 进度条隐藏完整 IP（非 -f 模式下使用 $IPhide，彻底杜绝检测过程中终端实时进度条泄露完整 IP）
    /echo -ne "\\r\$Font_Cyan\$Font_B\[\$IP\]#/ {
        gsub(/\[\$IP\]#/, "[$(if [ $fullIP -eq 1 ]; then echo \"$IP\"; else echo \"${IPhide:-$IP}\"; fi)]#")
    }
    # 2. check_connectivity 走代理/指定网卡 ($CurlARG)，防止旁路裸连泄露宿主机真实 IP
    /http_code=\$\(curl -s -o \/dev\/null -w "%\{http_code\}" --connect-timeout "\$timeout" "\$url"/ {
        gsub(/curl -s -o/, "curl $CurlARG -s -o")
    }
    # 3. get_ipv4 遵循 -6 (IPV4check=0) 跳过探测，避免多余请求与 IPv4 泄露
    /^get_ipv4\(\)\{$/ { in_get4 = 1 }
    in_get4 && /^IPV4=""$/ {
        print
        print "[[ $IPV4check -eq 0 ]] && { IPV4work=0; return 0; }"
        in_get4 = 0
        next
    }
    # 4. get_ipv6 遵循 -4 (IPV6check=0) 跳过探测，避免多余请求与 IPv6 泄露
    /^get_ipv6\(\)\{$/ { in_get6 = 1 }
    in_get6 && /^IPV6=""$/ {
        print
        print "[[ $IPV6check -eq 0 ]] && { IPV6work=0; return 0; }"
        in_get6 = 0
        next
    }
    # 5. 修复 macOS/BSD sed 下 hide_ipv6 正则 \+ 不兼容问题
    /sed \x27s\/::\\\+\/:\/g\x27/ {
        gsub(/sed \x27s\/::\\\+\/:\/g\x27/, "sed \x27s/::\\{1,\\}/:/g\x27")
    }
    # 6. db_ipinfo 拉取 iso3166.json 与 show_ad 走 $CurlARG，避免旁路请求
    /ISO3166=\$\(curl -sL -m 10 "\$\{rawgithub\}main\/ref\/iso3166\.json"\)/ {
        gsub(/curl -sL/, "curl $CurlARG -sL")
    }
    /content=\$\(curl -fsL --max-time 5 "\$\{rawgithub\}main\/ref\/ad\$i\.ans"\)/ {
        gsub(/curl -fsL/, "curl $CurlARG -fsL")
    }
    /aad\[0\]=\$\(curl -sL --max-time 5 "\$\{rawgithub\}main\/ref\/sponsor\.ans"\)/ {
        gsub(/curl -sL/, "curl $CurlARG -sL")
    }
    # 7. 支持通过 0600 临时配置文件传递代理 (-K)，防止 ps aux 进程表泄露代理账号密码
    /^usePROXY=" -x \$xproxy"$/ {
        print "if [[ -n \"${IPZHILIANG_CURL_CFG:-}\" && -f \"${IPZHILIANG_CURL_CFG:-}\" ]]; then usePROXY=\" -K ${IPZHILIANG_CURL_CFG}\"; else usePROXY=\" -x $xproxy\"; fi"
        next
    }
    # 8. get_opts 结尾：仅在未指定 -i / -x 时才按已解析的 -4/-6 探测默认出口 IP
    /^\[\[ \$IPV4check -eq 1 && \$IPV6check -eq 0 && \$IPV4work -eq 0 \]\]&&ERRORcode=40$/ {
        print "if [[ -z $useNIC && -z $usePROXY ]]; then get_ipv4; get_ipv6; is_valid_ipv4 $IPV4; is_valid_ipv6 $IPV6; fi"
    }
    # 9. 报告上传控制：隐私模式物理级阻断 upload.check.place；公开模式走 $CurlARG
    /https:\/\/upload\.check\.place/ {
        if (privacy_no_upload == "1") {
            print "report_link=\"\""
            next
        } else {
            gsub(/curl -\$2 -s -X POST https:\/\/upload\.check\.place/, "curl $CurlARG -$2 -s -X POST https://upload.check.place")
        }
    }
    # 10. 启动阶段先执行 get_opts 解析 -x/-i/-4/-6，绝不在解析参数前裸连探测宿主机默认 IP
    /^check_connectivity$/ {
        skip_pre_init = 1
        next
    }
    skip_pre_init && /^(read_ref|get_ipv4|get_ipv6|is_valid_ipv4 \$IPV4|is_valid_ipv6 \$IPV6)$/ {
        next
    }
    skip_pre_init && /^get_opts "\$@"$/ {
        print "get_opts \"$@\""
        print "[[ $ERRORcode -eq 0 ]] && check_connectivity"
        print "[[ $ERRORcode -eq 0 ]] && read_ref"
        skip_pre_init = 0
        next
    }
    # 11. 禁用 clear 清屏，防止抹除配置总览及多端口批量检测时的前序报告
    /^clear$/ {
        print ": # clear disabled"
        next
    }
    { print }
    ' "$script_file" > "$patched_file" 2>/dev/null || true

    if [[ -s "$patched_file" ]] && "$BASH4_BIN" -n "$patched_file" 2>/dev/null; then
        chmod 600 "$patched_file" 2>/dev/null || true
        mv -f "$patched_file" "$script_file"
    else
        rm -f "$patched_file"
    fi
}

download_upstream_script() {
    TMP_SCRIPT=$(make_temp_file "ipzhiliang")
    local ts
    ts=$(date +%s)
    echo -e "${C_DIM}正在实时拉取最新 IP 质量检测引擎与数据库...${C_RESET}"
    if curl -fsL --connect-timeout 8 --max-time 25 -H "Cache-Control: no-cache" -H "Pragma: no-cache" "$UPSTREAM_PRIMARY" -o "$TMP_SCRIPT" 2>/dev/null && [[ -s "$TMP_SCRIPT" ]] && grep -q "script_version=" "$TMP_SCRIPT" 2>/dev/null; then
        local up_ver
        up_ver=$(grep -m1 '^script_version=' "$TMP_SCRIPT" | cut -d'"' -f2)
        patch_upstream_script "$TMP_SCRIPT"
        [[ -n "$up_ver" ]] && echo -e "${C_GREEN}[已同步] 上游检测引擎版本: ${up_ver} (IP.Check.Place 实时最新 · 已启用隐私加固)${C_RESET}"
        return 0
    fi
    echo -e "${C_YELLOW}主源下载超时，正在切换至 GitHub 备用源...${C_RESET}"
    if curl -fsL --connect-timeout 10 --max-time 30 -H "Cache-Control: no-cache" "${UPSTREAM_FALLBACK}?t=${ts}" -o "$TMP_SCRIPT" 2>/dev/null && [[ -s "$TMP_SCRIPT" ]] && grep -q "script_version=" "$TMP_SCRIPT" 2>/dev/null; then
        local up_ver
        up_ver=$(grep -m1 '^script_version=' "$TMP_SCRIPT" | cut -d'"' -f2)
        patch_upstream_script "$TMP_SCRIPT"
        [[ -n "$up_ver" ]] && echo -e "${C_GREEN}[已同步] 上游检测引擎版本: ${up_ver} (GitHub 备用源 · 已启用隐私加固)${C_RESET}"
        return 0
    fi
    echo -e "${C_RED}[错误] 无法下载上游检测脚本，请检查网络连接。${C_RESET}"
    exit 1
}

# 多端口导出时为每个端口生成独立文件名，避免上游 -o 报文件已存在
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

# 准备导出文件路径：若已存在旧同名文件则先清理（防止上游报错退出码 10）
prepare_output_file() {
    local out_path="$1"
    [[ -z "$out_path" ]] && return 0
    if [[ -f "$out_path" ]]; then
        rm -f "$out_path" 2>/dev/null || true
    fi
}

# 导出完成后收紧报告文件权限为 0600，防止同机其他非特权用户读取
secure_output_file() {
    local out_path="$1"
    [[ -z "$out_path" ]] && return 0
    if [[ -f "$out_path" ]]; then
        chmod 600 "$out_path" 2>/dev/null || true
    fi
}

execute_checks() {
    align_iface_ip_stack
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo -e "${C_YELLOW}[Dry-Run] 仅预览将执行的命令，不实际运行：${C_RESET}"
        if [[ "$TARGET_MODE" == "port" ]]; then
            local i=1 total=${#TARGET_PORTS[@]} p out_path
            for p in "${TARGET_PORTS[@]}"; do
                out_path=$(derive_output_path "$OUTPUT_FILE" "$i" "$total")
                build_upstream_args "$p" "$out_path"
                echo "  [$i/$total] $(format_preview_cmd)"
                i=$((i + 1))
            done
        else
            build_upstream_args "" "$OUTPUT_FILE"
            echo "  $(format_preview_cmd)"
        fi
        return 0
    fi

    download_upstream_script

    if [[ "$TARGET_MODE" == "port" ]]; then
        local i=1 total=${#TARGET_PORTS[@]} p out_path
        local use_cfg_file=0
        if grep -q 'IPZHILIANG_CURL_CFG' "$TMP_SCRIPT" 2>/dev/null; then
            TMP_CURL_CFG=$(make_temp_file "ipzhiliang_curl")
            use_cfg_file=1
        fi

        for p in "${TARGET_PORTS[@]}"; do
            out_path=$(derive_output_path "$OUTPUT_FILE" "$i" "$total")
            prepare_output_file "$out_path"
            echo ""
            echo -e "${C_BOLD}${C_GREEN}>>> [${i}/${total}] 正在检测端口/代理: $(mask_proxy_url "$p")${C_RESET}"
            if [[ $use_cfg_file -eq 1 ]]; then
                printf 'proxy = "%s"\n' "$p" > "$TMP_CURL_CFG"
                chmod 600 "$TMP_CURL_CFG" 2>/dev/null || true
                # 命令行仅传入脱敏后的占位代理字符串，真实代理与密码经由 0600 配置文件读取，彻底杜绝 ps aux 泄露
                build_upstream_args "$(mask_proxy_url "$p")" "$out_path"
                IPZHILIANG_CURL_CFG="$TMP_CURL_CFG" "$BASH4_BIN" "$TMP_SCRIPT" "${UPSTREAM_ARGS[@]}"
            else
                build_upstream_args "$p" "$out_path"
                "$BASH4_BIN" "$TMP_SCRIPT" "${UPSTREAM_ARGS[@]}"
            fi
            secure_output_file "$out_path"
            i=$((i + 1))
        done
    else
        prepare_output_file "$OUTPUT_FILE"
        build_upstream_args "" "$OUTPUT_FILE"
        echo ""
        echo -e "${C_BOLD}${C_GREEN}>>> 正在启动 IP 质量检测...${C_RESET}"
        "$BASH4_BIN" "$TMP_SCRIPT" "${UPSTREAM_ARGS[@]}"
        secure_output_file "$OUTPUT_FILE"
    fi
}

# 校验需要参数的 CLI 选项
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
    local cli_privacy="" cli_full=0 cli_ports=""

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
                cli_privacy="privacy"
                shift
                ;;
            --public)
                NON_INTERACTIVE=1
                cli_privacy="public"
                shift
                ;;
            --full)
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
                    echo -e "${C_RED}[错误] 不支持的语言代码: $2 (可选: cn|en|jp|es|de|fr|ru|pt)${C_RESET}"
                    exit 1
                fi
                shift 2
                ;;
            -l=*)
                NON_INTERACTIVE=1
                if ! LANG_CODE=$(normalize_lang_code "${1#*=}"); then
                    echo -e "${C_RED}[错误] 不支持的语言代码: ${1#*=} (可选: cn|en|jp|es|de|fr|ru|pt)${C_RESET}"
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

    # 组合 CLI 隐私参数
    if [[ "$cli_privacy" == "public" && "$cli_full" -eq 1 ]]; then
        PRIVACY_MODE="3"
    elif [[ "$cli_privacy" == "public" ]]; then
        PRIVACY_MODE="2"
    elif [[ "$cli_full" -eq 1 ]]; then
        PRIVACY_MODE="4"
    else
        PRIVACY_MODE="1"
    fi

    # 解析 CLI 传入的 --port
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
            echo -e "操作: ${C_GREEN}[Enter]${C_RESET} 开始检测  |  ${C_PURPLE}[a]${C_RESET} 高级选项(语言/导出/JSON)  |  ${C_YELLOW}[r]${C_RESET} 重新配置  |  ${C_RED}[q]${C_RESET} 退出"
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
    parse_cli_args "$@"
    check_env
    print_banner
    check_self_update "$@"

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        show_summary
        execute_checks
    else
        interactive_loop
    fi
}

main "$@"

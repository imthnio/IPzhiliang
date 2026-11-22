#!/usr/bin/env bash
# ==============================================================================
# IPzhiliang - IP 质量交互式一键检测脚本
# GitHub: https://github.com/imthnio/IPzhiliang
# 上游核心检测引擎: https://github.com/xykt/IPQuality (https://IP.Check.Place)
# ==============================================================================

set -u

VERSION="1.2.1"
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

cleanup() {
    if [[ -n "$TMP_SCRIPT" && -f "$TMP_SCRIPT" ]]; then
        rm -f "$TMP_SCRIPT"
    fi
}
trap cleanup EXIT
trap 'echo -e "\n${C_YELLOW}已取消检测。${C_RESET}"; exit 130' INT TERM

# 兼容 `bash <(curl ...)` 和 `curl ... | bash` 的安全读取函数
# 注意：内部变量使用 __tty_ 前缀，避免与调用方传入的变量名冲突
tty_read() {
    local __tty_prompt="$1"
    local __tty_var="$2"
    local __tty_silent="${3:-0}"
    local __tty_val=""

    if [[ -r /dev/tty ]]; then
        if [[ "$__tty_silent" == "1" ]]; then
            read -r -s -p "$__tty_prompt" __tty_val </dev/tty
            echo "" >/dev/tty
        else
            read -r -p "$__tty_prompt" __tty_val </dev/tty
        fi
    else
        if [[ "$__tty_silent" == "1" ]]; then
            read -r -s -p "$__tty_prompt" __tty_val
            echo ""
        else
            read -r -p "$__tty_prompt" __tty_val
        fi
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
    elif command -v systemd-detect-virt >/dev/null 2>&1; then
        local v
        v=$(systemd-detect-virt 2>/dev/null || true)
        if [[ -n "$v" && "$v" != "none" ]]; then
            virt_type="${v}(小鸡)"
        fi
    elif [[ -r /sys/class/dmi/id/product_name ]]; then
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
  -o <路径>          将报告保存到本地文件 (.txt / .ansi / .json)
  -j                 以 JSON 格式输出
  -y                 自动安装缺失依赖 [默认]
  -n                 跳过系统与依赖检测
  --update           将本地 ipzhiliang.sh 更新到 GitHub 最新版本
  --dry-run          仅打印最终将执行的命令，不实际运行检测
  -h, --help         显示本帮助信息
EOF
}

# 兼容 GNU / BusyBox(Alpine) / macOS 的安全临时文件创建函数
make_temp_file() {
    local prefix="${1:-ipzhiliang}"
    local f=""
    if command -v mktemp >/dev/null 2>&1; then
        f=$(mktemp "${TMPDIR:-/tmp}/${prefix}.XXXXXX" 2>/dev/null) || f=""
    fi
    if [[ -z "$f" ]]; then
        f="${TMPDIR:-/tmp}/${prefix}.$$.${RANDOM:-0}"
        : > "$f"
    fi
    echo "$f"
}

# 本地脚本自更新
self_update() {
    local target_path="${BASH_SOURCE[0]:-}"
    if [[ -z "$target_path" || ! -f "$target_path" || "$target_path" == /dev/fd/* || "$target_path" == /proc/self/fd/* ]]; then
        echo -e "${C_GREEN}[提示] 你正在通过远程一键命令运行，每次执行已自动拉取最新版脚本与检测数据库。${C_RESET}"
        exit 0
    fi

    echo -e "${C_DIM}正在从 GitHub 拉取最新 ipzhiliang.sh ...${C_RESET}"
    local tmp_new
    tmp_new=$(make_temp_file "ipzhiliang_update")
    if curl -fsL --connect-timeout 8 --max-time 20 -H "Cache-Control: no-cache" "${SELF_RAW_URL}?t=$(date +%s)" -o "$tmp_new" 2>/dev/null && grep -q "IPzhiliang" "$tmp_new"; then
        local new_ver
        new_ver=$(grep -m1 '^VERSION=' "$tmp_new" | cut -d'"' -f2)
        chmod +x "$tmp_new"
        mv "$tmp_new" "$target_path"
        echo -e "${C_GREEN}[成功] 已更新至最新版本 v${new_ver:-unknown} (${target_path})${C_RESET}"
        exit 0
    else
        rm -f "$tmp_new"
        echo -e "${C_RED}[错误] 自更新失败，请检查网络连接后重试。${C_RESET}"
        exit 1
    fi
}

# 若以本地文件方式运行，全自动检查并直接静默更新到最新版本（2秒超时，不阻塞）
check_self_update() {
    local target_path="${BASH_SOURCE[0]:-}"
    if [[ -z "$target_path" || ! -f "$target_path" || "$target_path" == /dev/fd/* || "$target_path" == /proc/self/fd/* ]]; then
        return 0
    fi
    [[ "$DRY_RUN" -eq 1 ]] && return 0

    local remote_ver
    remote_ver=$(curl -fsL --connect-timeout 2 --max-time 3 -H "Cache-Control: no-cache" "${SELF_RAW_URL}?t=$(date +%s)" 2>/dev/null | grep -m1 '^VERSION=' | cut -d'"' -f2)
    if [[ -n "$remote_ver" && "$remote_ver" != "$VERSION" ]]; then
        echo -e "${C_CYAN}[自动更新] 发现新版本 v${remote_ver} (当前 v${VERSION})，正在自动更新...${C_RESET}"
        local tmp_new
        tmp_new=$(make_temp_file "ipzhiliang_update")
        if curl -fsL --connect-timeout 8 --max-time 20 -H "Cache-Control: no-cache" "${SELF_RAW_URL}?t=$(date +%s)" -o "$tmp_new" 2>/dev/null && grep -q "IPzhiliang" "$tmp_new"; then
            chmod +x "$tmp_new"
            mv "$tmp_new" "$target_path"
            echo -e "${C_GREEN}[自动更新] 已更新至 v${remote_ver}，正在无缝启动新版...${C_RESET}"
            echo ""
            exec bash "$target_path" "$@"
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

# 隐藏代理 URL 中的密码用于屏幕显示
mask_proxy_url() {
    local url="$1"
    if [[ "$url" == *"@"* ]]; then
        local proto="${url%%://*}"
        local rest="${url#*://}"
        local creds="${rest%%@*}"
        local hostpart="${rest#*@}"
        if [[ "$creds" == *":"* ]]; then
            local user="${creds%%:*}"
            echo "${proto}://${user}:***@${hostpart}"
            return
        fi
    fi
    echo "$url"
}

# 打码 IPv4/IPv6 用于隐私预览
mask_ip() {
    local ip="$1"
    if [[ "$ip" == *":"* ]]; then
        # IPv6: 保留前两段
        echo "$ip" | awk -F: '{print $1":"$2":*:*:*"}'
    elif [[ "$ip" == *"."* ]]; then
        # IPv4: 保留前两段
        echo "$ip" | awk -F. '{print $1"."$2".*.*"}'
    else
        echo "$ip"
    fi
}

# 检测端口是否在本机监听，并返回监听地址提示
check_local_port_listen() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep -E ":${port}([[:space:]]|$)" | head -n 3
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | grep -E "[:.]${port}([[:space:]]|$)" | head -n 3
    elif command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | tail -n +2 | head -n 3
    fi
}

# 列出本机正在监听的常用本地端口（辅助用户参考）
show_listening_ports_hint() {
    local lines=""
    if command -v ss >/dev/null 2>&1; then
        lines=$(ss -tulnp 2>/dev/null | awk 'NR>1 && $1 ~ /tcp/ {print $5, $7}' | head -n 12)
    elif command -v netstat >/dev/null 2>&1; then
        lines=$(netstat -tuln 2>/dev/null | awk 'NR>2 && $1 ~ /tcp/ {print $4}' | head -n 12)
    elif command -v lsof >/dev/null 2>&1; then
        lines=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9, $1}' | head -n 12)
    fi

    if [[ -n "$lines" ]]; then
        echo -e "${C_DIM}当前本机部分监听端口参考:${C_RESET}"
        echo "$lines" | sed 's/^/  /'
        echo ""
    fi
}

# 通过指定代理探测出口 IP
probe_proxy_ip() {
    local proxy_url="$1"
    local ip=""
    local endpoints=("https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com")
    local ep
    for ep in "${endpoints[@]}"; do
        ip=$(curl -x "$proxy_url" -fsL --connect-timeout 4 --max-time 6 "$ep" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$ip" && ${#ip} -le 45 ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 自动探测纯端口或 host:port 的代理协议 (socks5h -> http -> https)
resolve_port_to_proxy() {
    local raw="$1"
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
            echo -e "${C_YELLOW}[警告] 暂未能通过 $(mask_proxy_url "$raw") 获取出口 IP（可能是网络较慢或仅支持 IPv6）。${C_RESET}" >&2
            echo "$raw"
            return 2
        fi
    fi

    # 纯端口号 -> 补全 127.0.0.1:PORT
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        if (( raw < 1 || raw > 65535 )); then
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
        hostport="$raw"
    fi

    echo -e "${C_DIM}正在自动探测 ${hostport} 的代理协议 (SOCKS5 / HTTP / HTTPS)...${C_RESET}" >&2
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

    echo -e "${C_RED}[失败] 无法通过 SOCKS5 / HTTP / HTTPS 连接 ${hostport}。${C_RESET}" >&2
    echo -e "${C_YELLOW}常见原因排查:${C_RESET}" >&2
    echo "  1. 该端口需要用户名/密码认证（请提供账号密码或完整代理 URL）" >&2
    echo "  2. 该端口是 VLESS/VMess/Trojan/SS 等节点入站，并非直接的 SOCKS5/HTTP 代理端口" >&2
    echo "     -> 如需测试该节点出口，可在面板中开一个本地 SOCKS5/HTTP 出站分流端口，或使用【指定网卡/出口 IP】模式" >&2
    echo "  3. 服务未启动或未监听在 127.0.0.1" >&2
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
                    auth_prefix="${p_user}:${p_pass}@"
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
                        if [[ "$item" =~ ^[0-9]+$ ]]; then
                            TARGET_PORTS+=("${m_proto}://${auth_prefix}127.0.0.1:${item}")
                        else
                            TARGET_PORTS+=("${m_proto}://${auth_prefix}${item}")
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
    local ifaces=()
    if command -v ip >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && ifaces+=("$line")
        done < <(ip -o -4 addr show 2>/dev/null | awk '$2 != "lo" {print $2 " (" $4 ")"}')
        while IFS= read -r line; do
            [[ -n "$line" ]] && ifaces+=("$line")
        done < <(ip -o -6 addr show scope global 2>/dev/null | awk '$2 != "lo" {print $2 " (" $4 ")"}')
    elif command -v ifconfig >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && ifaces+=("$line")
        done < <(ifconfig 2>/dev/null | awk '/^[a-zA-Z0-9_-]+:/ {iface=$1; sub(":","",iface)} /inet / && iface!="lo" && iface!="lo0" {print iface " (" $2 ")"}')
    fi

    if [[ ${#ifaces[@]} -gt 0 ]]; then
        echo -e "${C_CYAN}检测到本机以下网卡与地址：${C_RESET}"
        local idx=1
        local entry
        for entry in "${ifaces[@]}"; do
            echo -e "  ${C_GREEN}${idx})${C_RESET} ${entry}"
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
        if [[ "$iface_input" =~ ^[0-9]+$ ]] && (( iface_input >= 1 && iface_input <= ${#ifaces[@]} )); then
            local selected="${ifaces[$((iface_input - 1))]}"
            # 提取括号里的具体 IP（去掉 /前缀），多 IP 网卡可直接精准绑定到选中的那个 IP
            local extracted_ip
            extracted_ip=$(echo "$selected" | sed -E 's/.*\(([^)/]+)(\/[0-9]+)?\).*/\1/')
            if [[ -n "$extracted_ip" && "$extracted_ip" != "$selected" ]]; then
                TARGET_IFACE="$extracted_ip"
            else
                TARGET_IFACE="${selected%% *}"
            fi
        else
            TARGET_IFACE="$iface_input"
        fi
        break
    done
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

# 可选高级选项菜单
step_advanced_options() {
    echo ""
    echo -e "${C_BOLD}${C_PURPLE}=== 高级选项设置 ===${C_RESET}"

    # 1. 报告语言
    echo -e "1) 报告语言 (当前: ${C_CYAN}${LANG_CODE}${C_RESET})"
    echo "   可选: cn (中文) | en (English) | jp | es | de | fr | ru | pt"
    local lang_in=""
    tty_read "   请输入语言代码 (直接回车保持 ${LANG_CODE}): " lang_in
    if [[ -n "$lang_in" ]]; then
        LANG_CODE=$(echo "$lang_in" | tr '[:upper:]' '[:lower:]')
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

    # IP 协议栈
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

# 生成安全脱敏后的命令预览字符串
format_preview_cmd() {
    local preview="bash <(curl -Ls https://IP.Check.Place)"
    local skip_next=0
    local arg
    for arg in "${UPSTREAM_ARGS[@]}"; do
        if [[ $skip_next -eq 1 ]]; then
            preview+=" '$(mask_proxy_url "$arg")'"
            skip_next=0
            continue
        fi
        if [[ "$arg" == "-x" ]]; then
            preview+=" -x"
            skip_next=1
        else
            preview+=" $arg"
        fi
    done
    echo "$preview"
}

show_summary() {
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
            echo -e "  检测目标: ${C_GREEN}指定网卡/出口 IP${C_RESET} -> ${TARGET_IFACE}"
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

download_upstream_script() {
    TMP_SCRIPT=$(make_temp_file "ipzhiliang")
    local ts
    ts=$(date +%s)
    echo -e "${C_DIM}正在实时拉取最新 IP 质量检测引擎与数据库...${C_RESET}"
    if curl -fsL --connect-timeout 8 --max-time 25 -H "Cache-Control: no-cache" -H "Pragma: no-cache" "$UPSTREAM_PRIMARY" -o "$TMP_SCRIPT" 2>/dev/null && [[ -s "$TMP_SCRIPT" ]]; then
        local up_ver
        up_ver=$(grep -m1 '^script_version=' "$TMP_SCRIPT" | cut -d'"' -f2)
        [[ -n "$up_ver" ]] && echo -e "${C_GREEN}[已同步] 上游检测引擎版本: ${up_ver} (IP.Check.Place 实时最新)${C_RESET}"
        return 0
    fi
    echo -e "${C_YELLOW}主源下载超时，正在切换至 GitHub 备用源...${C_RESET}"
    if curl -fsL --connect-timeout 10 --max-time 30 -H "Cache-Control: no-cache" "${UPSTREAM_FALLBACK}?t=${ts}" -o "$TMP_SCRIPT" 2>/dev/null && [[ -s "$TMP_SCRIPT" ]]; then
        local up_ver
        up_ver=$(grep -m1 '^script_version=' "$TMP_SCRIPT" | cut -d'"' -f2)
        [[ -n "$up_ver" ]] && echo -e "${C_GREEN}[已同步] 上游检测引擎版本: ${up_ver} (GitHub 备用源)${C_RESET}"
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

execute_checks() {
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
        for p in "${TARGET_PORTS[@]}"; do
            out_path=$(derive_output_path "$OUTPUT_FILE" "$i" "$total")
            build_upstream_args "$p" "$out_path"
            echo ""
            echo -e "${C_BOLD}${C_GREEN}>>> [${i}/${total}] 正在检测端口/代理: $(mask_proxy_url "$p")${C_RESET}"
            "$BASH4_BIN" "$TMP_SCRIPT" "${UPSTREAM_ARGS[@]}"
            i=$((i + 1))
        done
    else
        build_upstream_args "" "$OUTPUT_FILE"
        echo ""
        echo -e "${C_BOLD}${C_GREEN}>>> 正在启动 IP 质量检测...${C_RESET}"
        "$BASH4_BIN" "$TMP_SCRIPT" "${UPSTREAM_ARGS[@]}"
    fi
}

parse_cli_args() {
    local cli_privacy="" cli_full=0 cli_ports=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)
                NON_INTERACTIVE=1
                TARGET_MODE="port"
                cli_ports="${2:-}"
                shift 2
                ;;
            --iface)
                NON_INTERACTIVE=1
                TARGET_MODE="iface"
                TARGET_IFACE="${2:-}"
                shift 2
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
                NON_INTERACTIVE=1
                LANG_CODE="${2:-cn}"
                shift 2
                ;;
            -E)
                NON_INTERACTIVE=1
                LANG_CODE="en"
                shift
                ;;
            -o)
                NON_INTERACTIVE=1
                OUTPUT_FILE="${2:-}"
                shift 2
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
        local item resolved rc
        for item in "${items[@]}"; do
            [[ -z "$item" ]] && continue
            if [[ "$DRY_RUN" -eq 1 && "$item" =~ ^[0-9]+$ ]]; then
                TARGET_PORTS+=("socks5h://127.0.0.1:${item}")
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

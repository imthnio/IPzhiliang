# IPzhiliang · 独立开源隐私优先 IP 质量一键检测工具

**100% 独立自研**的中文/英文交互式 IP 质量与 AI / 流媒体解锁检测脚本，主打**零第三方中转、零报告上传、零广告统计、全链路隐私脱敏、并发极速检测**，特别适合单机多出口、多端口代理分流（如端口 `21233` 走独立出口 IP）的 VPS 与本地环境。

## 一键运行（全系统通用）

```sh
(command -v curl >/dev/null && curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/run.sh || wget -qO- https://raw.githubusercontent.com/imthnio/IPzhiliang/main/run.sh) | sh
```

> 自动识别 Alpine / Debian / Ubuntu / CentOS / Rocky / Arch / OpenWrt / FreeBSD / macOS，缺失 `curl` / `bash` / `jq` 时自动补齐；完整兼容 macOS 自带 Bash 3.2 与 Linux Bash 4/5，全程免手动配置。

## 核心特点

### 1. 100% 独立引擎 · 真正隐私优先
- **零中转 / 零上传 / 零广告 / 零打点**：所有检测直接由本机或指定代理向公开权威数据源与目标服务发起，绝不上传任何报告到第三方站点，无任何统计上报与广告请求。
- **全链路 IP 与凭据脱敏**：
  - 默认**隐私打码模式**，从实时进度条、网卡列表、监听端口提示到最终报告与 JSON 输出，全程保留首尾、中间段打码（如 `203.*.*.55`、`2409:8a20:*:*:f294`），录屏/截图绝不泄露完整公网 IP，且能清晰区分同 C 段多出口 IP；
  - 代理账号密码经由 `0600` 权限临时配置文件通过 `curl -K` 传递，**绝不出现在 `ps aux` 进程列表中**，并自动对含 `@`、`:` 等特殊字符的密码进行 URL 编码；
  - 代理模式下严格使用 `socks5h`（远端解析 DNS），**DNSBL 黑名单强制经由代理走 DoH (DNS-over-HTTPS) 扫描**，并自动跳过直连 25 端口探测，杜绝任何旁路 DNS / 宿主机 IP 泄露；
  - 本地导出的 `.txt` / `.ansi` / `.json` 报告自动收紧为 `0600` 权限。

### 2. 并发极速多维检测（约 6~12 秒完成全套体检）
1. **基础信息融合校验**：融合 `IPinfo`、`IPQuery`、`ProxyCheck`、`IP-API`、`IP2Location` 多源互验，展示 ASN、组织/运营商、rDNS、实际使用地、注册归属地、**原生 IP / 广播 IP** 判定、时区与 Anycast 属性。
2. **多库风控评分与综合纯净度评级**：并行直连 `Scamalytics`、`ProxyCheck`、`IPQuery` 计算 `0–100` 风险分与可视化进度条，并结合黑名单命中情况给出综合风控评级；支持通过环境变量 `ABUSEIPDB_API_KEY` / `IPQS_API_KEY` 扩展自有官方 Key 直连查询。
3. **六源风险因子交叉矩阵**：横向交叉对比 `IPinfo` / `IPQuery` / `ProxyCheck` / `Scamalytics` / `IP-API` / `IP2Location` 的地区一致性、Proxy、VPN、Tor、机房/服务器、移动网络、爬虫标记。
4. **AI 与流媒体并发解锁检测**：一键并发探测 **ChatGPT、Claude、Gemini、Netflix（区分全解锁/仅自制）、Disney+、YouTube Premium、TikTok、Amazon Prime Video、Reddit** 的解锁状态与地区。
5. **邮局 25 端口与 22+ 权威 DNSBL 黑名单扫描**：内置 22 个经 RFC 5782 验证的权威公开 RBL 库并发扫描（命中时直接列出黑名单域名，方便排查申诉）。

### 3. 灵活的目标选择与多端口批量检测
- **整台机器（默认出口）**：直接检测当前机器 IPv4 / IPv6 公网出口。
- **指定端口 / 代理（如 `21233`）**：
  - 只需输入端口号（如 `21233`），自动探测 `SOCKS5H` / `HTTP` / `HTTPS` 协议并预览脱敏出口 IP；
  - 支持**多端口逗号分隔批量检测**（如 `21233,21234,21235`），自动顺序输出结果且互不清屏覆盖；
  - 支持账号密码认证及完整代理 URL（`socks5h://user:pass@127.0.0.1:21233`）。
- **指定网卡或指定出口 IP**：自动列出本机网卡与脱敏 IPv4/IPv6 地址，输入编号即可精准绑定检测，并自动对齐 IPv4/IPv6 协议栈。

## 命令行快捷模式

```bash
# 仅测本机默认出口 IPv4（隐私打码模式）
bash <(curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh) -4

# 仅测 21233 端口（自动探测协议 + 隐私打码模式）
bash <(curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh) --port 21233

# 批量检测多个端口并导出脱敏报告（自动生成 report_1.txt / report_2.txt，权限 0600）
bash <(curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh) --port 21233,21234 -o report.txt

# 检测指定网卡（如 warp）并输出结构化 JSON
bash <(curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh) --iface warp -4 -j

# 仅本地查看完整 IP（不上传，零中转）
bash <(curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh) --full

# 可选：携带自有官方 API Key 启用 AbuseIPDB / IPQS 直连扩展
ABUSEIPDB_API_KEY="your_key" IPQS_API_KEY="your_key" bash ipzhiliang.sh -4

# 查看全部参数
bash <(curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh) --help
```

## 依赖要求

- `bash`（完整兼容 Bash 3.2+，macOS 无需升级 Bash 即可直接运行）
- `curl`、`jq`（通过 `run.sh` 一键运行或默认 `-y` 模式下自动安装）
- 可选：`dig`、`nc`（用于直连模式 DNSBL 与 25 端口探测；缺失时 DNSBL 自动回退至 DoH）

## 开源许可

本项目采用 [MIT License](./LICENSE) 开源，所有核心代码与黑名单配置均为独立实现。

# IPzhiliang · IP 质量一键交互检测脚本

基于 [xykt/IPQuality](https://github.com/xykt/IPQuality)（`https://IP.Check.Place`）构建的中文交互式一键封装脚本，主打**零记忆参数、自动识别端口代理协议、清晰的隐私保护选项**，特别适合单机多出口、多端口代理分流（如端口 `21233` 走独立出口 IP）的 VPS 环境。

<!-- UPSTREAM_STATUS_START -->
> 上游同步状态：核心引擎 `v2026-11-07` · 上游提交 `8643bcd` · 黑名单数据库 `424` 条 · 最近自动同步 `2026-11-22T15:07:48Z`
<!-- UPSTREAM_STATUS_END -->

## 一键运行（全系统通用）

```sh
(command -v curl >/dev/null && curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/run.sh || wget -qO- https://raw.githubusercontent.com/imthnio/IPzhiliang/main/run.sh) | sh
```

> 自动识别 Alpine / Debian / Ubuntu / CentOS / Rocky / Arch / macOS，无 `curl` 或无 `bash` 时会自动通过 `wget` 拉取并自动补齐依赖，全程免手动操作。

## 核心功能

1. **灵活选择检测目标**
   - **整台机器（默认出口）**：直接检测当前服务器默认公网出口。
   - **指定端口（如 `21233`）**：
     - 只需输入端口号（如 `21233`），脚本会**自动探测**该端口的代理协议（SOCKS5 / HTTP / HTTPS），并预览出口 IP。
     - 支持**多端口批量检测**（英文逗号分隔，如 `21233,21234,21235`）。
     - 支持带账号密码认证的代理，或直接输入完整代理 URL（`socks5://user:pass@127.0.0.1:21233`）。
     - 自动展示当前本机监听端口供参考；若端口不通会给出排查提示（如 VLESS/VMess/Trojan 节点端口与 SOCKS5/HTTP 端口的区别）。
   - **指定出口网卡或出口 IP**：自动列出本机可用网卡（如 `eth0`、`wg0`、`warp`）及地址，输入编号即可检测。

2. **清晰的隐私与公开选项**
   - **隐私保护模式（默认推荐）**：隐藏/打码 IP 地址，且**不上传**生成公开报告链接（`-p`）。
   - **公开分享模式（隐藏 IP）**：隐藏/打码 IP，生成可分享的 `Report.Check.Place` 公开报告链接。
   - **公开完整模式**：展示完整 IP 地址，并生成公开报告链接（`-f`）。
   - **本地完整模式**：仅在本地终端展示完整 IP，不上传公开报告链接（`-p -f`）。

3. **更多贴心交互**
   - **IP 协议版本选择**：双栈（IPv4 + IPv6）、仅 IPv4（`-4`）、仅 IPv6（`-6`）。
   - **执行前总览与脱敏预览**：开始检测前展示完整配置与等价命令（自动隐藏代理密码），支持按 `a` 进入高级选项、按 `r` 重新配置、按 `Enter` 直接开测。
   - **高级选项（按 `a`）**：切换报告语言（中/英/日/西/德/法/俄/葡）、导出报告到本地文件（`.txt` / `.ansi` / `.json`，多端口自动编号防覆盖）、终端 JSON 输出、依赖自动安装/跳过策略。
   - **自动同步最新数据库与引擎**：
     - 每次运行都会绕过缓存实时拉取最新 `IP.Check.Place` 引擎及黑名单/风险库，并在终端显示当前同步的上游版本号；
     - 仓库内置 GitHub Actions（`.github/workflows/sync-upstream.yml`），每日自动追踪 `xykt/IPQuality` 与数据库更新并同步 `upstream_meta.json`；若上游新增命令行参数，还会自动创建 Issue 提醒适配；
     - 本地保存的 `ipzhiliang.sh` 启动时自动检查新版本，也支持 `bash ipzhiliang.sh --update` 一键自更新。
   - **双源容错**：优先从 `https://IP.Check.Place` 拉取最新检测引擎，超时自动切换至 GitHub 备用源。

## 命令行快捷模式

除了默认交互菜单，也支持通过参数直接运行：

```bash
# 仅测 21233 端口（自动探测协议 + 默认隐私模式）
bash <(curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh) --port 21233

# 批量检测多个端口，且生成公开报告链接
bash <(curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh) --port 21233,21234 --public

# 检测指定网卡（如 warp）的 IPv4，隐私模式并保存报告
bash <(curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh) --iface warp -4 --privacy -o report.txt

# 仅预览最终命令，不实际执行
bash <(curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh) --port 21233 --dry-run

# 查看全部参数
bash <(curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/ipzhiliang.sh) --help
```

## 依赖要求

- `curl`
- `bash >= 4.0`（上游检测引擎要求；macOS 若使用系统自带 Bash 3.2，可通过 `brew install bash` 安装，脚本会自动识别）

## 致谢与许可

- 核心 IP 质量检测能力由开源项目 [xykt/IPQuality](https://github.com/xykt/IPQuality) 提供（遵循 GNU AGPL-3.0 协议），本脚本在运行时动态拉取其最新版本执行。
- 本仓库的交互封装脚本采用 [MIT License](./LICENSE) 开源。

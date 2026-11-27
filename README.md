# IPzhiliang · IP 质量一键交互检测脚本

## 一键运行（全系统通用）

```sh
(command -v curl >/dev/null && curl -Ls https://raw.githubusercontent.com/imthnio/IPzhiliang/main/run.sh || wget -qO- https://raw.githubusercontent.com/imthnio/IPzhiliang/main/run.sh) | sh
```

> 自动识别 Alpine / Debian / Ubuntu / CentOS / Rocky / Arch / macOS，无 `curl` 或无 `bash` 时会自动通过 `wget` 拉取并自动补齐依赖，全程免手动操作。

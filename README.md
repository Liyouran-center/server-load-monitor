# server-load-monitor

每分钟采集服务器负载(CPU/内存/loadavg),每小时打包归档;小时内出现负载过高时,
自动附加 CPU Top 5 进程快照并推送到 ntfy(支持 API Key 鉴权)。

## 一行安装(所有选项均可自定义)

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/server-load-monitor/main/install.sh | sudo bash -s --   --ntfy-url https://ntfy.example.com   --ntfy-topic server-load-alert   --api-key tk_xxxxxxxxxxxxxxxx   --load-threshold 1.5   --cpu-threshold 90   --mem-threshold 90   --install-dir /opt/load-monitor   --log-dir /var/log/load_monitor   --retention 7   --top-n 5
```

也可以用环境变量写法:

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/server-load-monitor/main/install.sh |   sudo NTFY_URL=https://ntfy.example.com NTFY_TOPIC=server-load-alert NTFY_API_KEY=tk_xxx bash
```

## 参数说明

| 参数 | 环境变量 | 默认值 | 说明 |
|---|---|---|---|
| `--ntfy-url` | `NTFY_URL` | `https://ntfy.sh` | ntfy 服务器地址 |
| `--ntfy-topic` | `NTFY_TOPIC` | `server-load-alert` | ntfy 主题 |
| `--api-key` | `NTFY_API_KEY` | 空 | ntfy 访问令牌 |
| `--load-threshold` | `LOAD_THRESHOLD` | `1.5` | load1/核数 阈值 |
| `--cpu-threshold` | `CPU_THRESHOLD` | `90` | CPU 使用率%阈值 |
| `--mem-threshold` | `MEM_THRESHOLD` | `90` | 内存使用率%阈值 |
| `--install-dir` | `INSTALL_DIR` | `/opt/load-monitor` | 程序安装目录 |
| `--log-dir` | `LOG_DIR` | `/var/log/load_monitor` | 日志根目录 |
| `--retention` | `RETENTION_DAYS` | `7` | 归档保留天数 |
| `--top-n` | `TOP_N` | `5` | 高负载时抓取进程数 |

优先级:命令行参数 > 环境变量 > 默认值。安装后可编辑 `/etc/load_monitor.conf` 调整。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/server-load-monitor/main/install.sh | sudo bash -s -- --uninstall
```

## 工作原理

- `load_monitor.sh record`(每分钟):采集指标写入 `load_YYYYMMDD_HH.log`,超阈值时追加 `ps` Top N 快照并打 `OVERLOAD` 标记。
- `load_monitor.sh pack`(每小时):打包上一小时日志为 `.gz`;该小时无 `OVERLOAD` 则只归档不推送,否则汇总峰值与进程快照,通过 `Authorization: Bearer <token>` 推送 ntfy。

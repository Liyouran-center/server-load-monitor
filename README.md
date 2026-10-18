# server-load-monitor

每分钟采集服务器负载(loadavg / CPU / 内存),每小时打包归档;一旦某小时内出现负载过高,
自动附加 CPU Top N 进程快照,并通过 [ntfy](https://ntfy.sh) 推送告警(支持 API Key 鉴权,可自建服务器)。

纯 Bash 实现,无第三方依赖,由 cron 驱动。

## 功能概览

- **每分钟采集**:1/5/15 分钟平均负载、CPU 使用率、内存使用率,写入按小时切分的日志。
- **过高时快照**:任一指标超过阈值,立即追加 `ps` 抓取的 CPU Top N 进程,并打上 `OVERLOAD` 标记。
- **每小时打包**:将上一小时日志压缩为 `.gz` 归档,自动清理过期归档。
- **按需告警**:仅当上一小时出现过 `OVERLOAD` 才推送;正常小时只归档、不打扰。

## 环境要求

- Linux,具备 `sudo`(root) 权限
- GNU coreutils(需要 `date -d`、`nproc`)
- `cron` / `crontab`
- `curl`、`gzip`、`gawk`(或 `awk`)
- `procps`(提供 `ps`、`top`)

Debian / Ubuntu 可一次性安装:

```bash
sudo apt install -y cron curl procps gawk gzip coreutils
```

CentOS / RHEL 系:

```bash
sudo yum install -y cronie curl procps-ng gawk gzip coreutils
```

## 一行安装

不带告警推送(只采集、归档):

```bash
curl -fsSL https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/main/install.sh | sudo bash
```

带全部参数(以下为示例值,请替换为你自己的):

```bash
curl -fsSL https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/main/install.sh | sudo bash -s -- \
  --ntfy-url https://ntfy.example.com \
  --ntfy-topic server-load-alert \
  --api-key tk_xxxxxxxxxxxxxxxx \
  --load-threshold 1.5 \
  --cpu-threshold 90 \
  --mem-threshold 90 \
  --install-dir /opt/load-monitor \
  --log-dir /var/log/load_monitor \
  --retention 7 \
  --top-n 5
```

> **安全提示**:命令行参数会被记录在 shell 历史和进程列表中。如果要传入 API Key,推荐使用环境变量写法:

```bash
curl -fsSL https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/main/install.sh \
  | sudo env NTFY_URL=https://ntfy.example.com NTFY_TOPIC=server-load-alert NTFY_API_KEY=tk_xxxxxxxxxxxxxxxx bash
```

> 请使用 `sudo env ...` 而不是 `sudo VAR=... bash`:后者取决于 sudoers 配置,部分系统会忽略变量。

如果已经 `git clone` 了仓库,也可以在本地直接运行:

```bash
git clone https://github.com/Liyouran-center/server-load-monitor.git
cd server-load-monitor
sudo ./install.sh --ntfy-url https://ntfy.example.com --api-key tk_xxxxxxxxxxxxxxxx
```

## 安装后验证

```bash
# 查看 cron 任务(应包含两条带 "# load-monitor" 标记的任务)
crontab -l

# 查看最新一条采集记录
tail -n 1 /var/log/load_monitor/load_*.log

# 手动触发一次打包(会按需推送告警)
sudo /opt/load-monitor/load_monitor.sh pack

# 发送一条测试通知,验证 ntfy 配置是否正确
sudo /opt/load-monitor/load_monitor.sh test
```

### 通知测试

`test` 命令会向配置的 ntfy 主题发送一条测试消息,并打印 HTTP 状态码:

```bash
sudo /opt/load-monitor/load_monitor.sh test
```

| 结果 | 含义 | 处理建议 |
|---|---|---|
| `HTTP 200` | 发送成功 | 去 ntfy 客户端确认是否收到消息 |
| `000` | 无法连接服务器 | 检查 `NTFY_URL`、网络和防火墙 |
| `401` / `403` | 鉴权失败 | 检查 `NTFY_API_KEY` 及主题的读写权限 |
| `404` | 地址或主题不存在 | 检查 `NTFY_URL` 与 `NTFY_TOPIC` |

测试命令成功返回 `0`,失败返回 `1`,可用于脚本或监控集成。它只发送一条消息,不会修改日志或归档。

## 参数说明

| 命令行参数 | 环境变量 | 默认值 | 说明 |
|---|---|---|---|
| `--ntfy-url` | `NTFY_URL` | `https://ntfy.sh` | ntfy 服务器地址 |
| `--ntfy-topic` | `NTFY_TOPIC` | `server-load-alert` | ntfy 主题 |
| `--api-key` | `NTFY_API_KEY` | 空 | ntfy 访问令牌;为空则不推送 |
| `--load-threshold` | `LOAD_THRESHOLD` | `1.5` | `load1 / CPU 核数` 的阈值 |
| `--cpu-threshold` | `CPU_THRESHOLD` | `90` | CPU 使用率(%)阈值 |
| `--mem-threshold` | `MEM_THRESHOLD` | `90` | 内存使用率(%)阈值 |
| `--install-dir` | `INSTALL_DIR` | `/opt/load-monitor` | 程序安装目录 |
| `--log-dir` | `LOG_DIR` | `/var/log/load_monitor` | 日志根目录 |
| `--retention` | `RETENTION_DAYS` | `7` | 归档保留天数 |
| `--top-n` | `TOP_N` | `5` | 高负载时抓取的进程数 |
| `--uninstall` | — | — | 卸载(见下文) |
| `-h`, `--help` | — | — | 显示帮助 |

优先级:**命令行参数 > 环境变量 > 默认值**。

## 配置文件

安装时会生成 `/etc/load_monitor.conf`(权限 `0600`,因为其中含有 API Key)。
修改后无需重启 cron,下一次执行 `record` / `pack` 即生效:

```bash
sudo nano /etc/load_monitor.conf
```

配置项与参数一一对应:`NTFY_URL`、`NTFY_TOPIC`、`NTFY_API_KEY`、`LOAD_PER_CORE_THRESHOLD`、
`CPU_PERCENT_THRESHOLD`、`MEM_PERCENT_THRESHOLD`、`BASE_DIR`、`HISTORY_DAYS`、`TOP_N`。

## 告警判定规则

每分钟的一次采集,只要满足以下任一条件即记为 `OVERLOAD`:

- `load1 / 核数 > LOAD_PER_CORE_THRESHOLD`
- `CPU 使用率 > CPU_PERCENT_THRESHOLD`
- `内存使用率 > MEM_PERCENT_THRESHOLD`

每小时整点 `pack` 运行时,检查**上一小时**的日志:

- 没有任何 `OVERLOAD`:仅压缩归档,**不推送**。
- 存在 `OVERLOAD`:推送一条高优先级告警,内容包括出现次数、负载峰值、最近一次的进程快照,以及归档文件名。

## 工作原理

| 任务 | 频率 | 动作 |
|---|---|---|
| `load_monitor.sh record` | 每分钟 | 采集指标写入 `load_YYYYMMDD_HH.log`;超阈值时追加 `ps` Top N 快照并打 `OVERLOAD` 标记 |
| `load_monitor.sh pack` | 每小时整点 | 检查上一小时日志 → 按需推送 ntfy → 压缩为 `archive/YYYYMMDD/*.gz` → 清理过期文件 |

日志文件示例(一行采集记录 + 一段过高快照):

```text
[2026-10-18 10:03:00] load1=0.52 load5=0.48 load15=0.40 cores=4 cpu%=12.3 mem%=45.6
[2026-10-18 10:07:00] load1=6.10 load5=3.20 load15=1.90 cores=4 cpu%=97.5 mem%=52.1
[2026-10-18 10:07:00] === OVERLOAD: top 5 processes by CPU ===
  PID  PPID USER      %CPU %MEM     ELAPSED COMMAND
 1234  1100 www-data  85.2  4.1    02:13:45 php-fpm
 ...
```

目录结构:

```text
/opt/load-monitor/
└── load_monitor.sh                 # 主程序
/etc/load_monitor.conf              # 配置文件(含 API Key,0600)
/var/log/load_monitor/
├── load_20261018_10.log            # 当前小时的原始日志
├── archive/
│   └── 20261017/
│       └── load_20261017_09.log.gz # 已打包的历史归档
└── cron.log                        # cron 执行输出(用于排错)
```

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/main/install.sh | sudo bash -s -- --uninstall
```

卸载会移除 cron 任务、`/etc/load_monitor.conf` 以及程序目录。**日志目录会保留**,如需删除请手动执行:

```bash
sudo rm -rf /var/log/load_monitor
```

> 如果安装时使用了自定义的 `--install-dir`,卸载时需要传入相同的参数,例如 `--install-dir /opt/my-monitor --uninstall`。

## 故障排查

- **没有收到告警**
  1. 确认安装时已提供 `--api-key`:`grep NTFY_API_KEY /etc/load_monitor.conf`(注意权限,需 root)。
  2. 手动触发:`sudo /opt/load-monitor/load_monitor.sh pack`,观察是否有 curl 报错。
  3. 检查 ntfy 服务器地址、主题名和令牌权限是否正确。
  4. 确认上一小时确实出现过 `OVERLOAD`:`grep -c OVERLOAD /var/log/load_monitor/load_*.log`。
- **没有日志生成**:`crontab -l` 检查任务是否存在;查看 `/var/log/load_monitor/cron.log`。
- **`record` 报 `top` 相关错误**:安装 `procps`,并确认 `top -bn1` 输出中包含 `%Cpu` 行。
- **阈值过于敏感或不灵敏**:调整 `LOAD_PER_CORE_THRESHOLD` 等值。负载阈值是相对于核数的,4 核机器上 `1.5` 即意味着 1 分钟平均负载达到 6。

## 注意事项

- `cron.log` 会随时间持续增长,不会被自动轮转。长期运行时可自行配置 `logrotate`。
- 归档保留天数由 `HISTORY_DAYS` 控制,单位为天,按文件修改时间清理。
- CPU 使用率来自 `top -bn1` 的一次快照,短时尖峰可能被平均掉;需要更精细的数据可调整采集频率。
- 通过 `curl | bash` 运行时,安装脚本会自动从本仓库下载 `load_monitor.sh`;如需使用 fork 或其他分支,可设置环境变量 `REPO_RAW` 指向对应的 raw 地址。

## 文件说明

| 文件 | 说明 |
|---|---|
| `install.sh` | 一键安装 / 卸载脚本,负责写入配置、安装 cron 任务 |
| `load_monitor.sh` | 采集、判断、打包、推送的主程序 |
| `README.md` | 本文档 |

# linux-health-monitor

轻量级 Linux 服务器健康检查脚本。纯 Bash 实现，只依赖 Linux 标准工具，由 cron 定时执行，
支持一行命令安装，不依赖任何第三方付费组件。

## 监控指标

| 指标 | 说明 | 默认阈值 |
|---|---|---|
| 负载 | 1 / 5 / 15 分钟平均负载（来自 `/proc/loadavg`） | — |
| 负载/核心比 | 1 分钟负载 ÷ CPU 核心数 | 1.0 |
| CPU 使用率 | `/proc/stat` 两次采样计算；失败时回退到 `top -bn1` | 90% |
| 内存真实使用率 | `free -m` 计算，排除缓存与缓冲区（总量 − available） | 90% |
| Swap 使用率 | `free -m` 计算；未配置 Swap 记为 0% | 80% |
| 磁盘使用率 | `df -P`，默认只检查 `/`，可通过 `DISK_MOUNTS` 追加挂载点 | 85% |
| 磁盘 inode 使用率 | `df -iP`，与磁盘挂载点一一对应 | 85% |
| 开机时长与启动时间 | `/proc/uptime` 与系统时间换算 | — |
| 进程总数与僵尸进程数 | `ps` 统计 | 僵尸 10 个 |

任一指标**严格超过**阈值即输出 `ALERT`，脚本返回退出码 `1`。
某项指标无法采集时显示为 `n/a`，不会导致脚本退出，也不会触发告警。

## 系统要求

- Linux（需要 `/proc` 文件系统）
- Bash 3.2 或更高版本（兼容 macOS 默认版本的语法，但仅在 Linux 上运行）
- GNU coreutils（`date -d`、`nproc`）、`procps`（`free`、`ps`、`top`）
- `curl`、`tar`、`crontab`（安装脚本需要；启用 ntfy 通知时 `curl` 也是运行时需要的）

Debian / Ubuntu：

```bash
sudo apt install -y cron curl tar procps coreutils
```

CentOS / RHEL：

```bash
sudo yum install -y cronie curl tar procps-ng coreutils
```

## 一行安装

> 请先阅读 [SECURITY.md](SECURITY.md)。对于生产服务器，推荐使用下面的"先下载、审查、再执行"方式。

```bash
curl -fsSL https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/main/install.sh | bash
```

默认行为：

- 普通用户运行：程序安装到 `~/.local/bin/linux-health-monitor`，配置到 `~/.config/linux-health-monitor.conf`，日志写入 `~/.local/state/linux-health-monitor.log`。
- root 运行：程序安装到 `/usr/local/bin/linux-health-monitor`，配置到 `/etc/linux-health-monitor.conf`，日志写入 `/var/log/linux-health-monitor.log`。
- 在当前用户的 crontab 中追加一组条目（每 5 分钟执行一次）。已存在则不会重复添加。

### 先下载、审查、再执行（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/main/install.sh -o install.sh
less install.sh
bash install.sh --dry-run    # 查看将要执行的全部操作，不修改系统
bash install.sh
```

### 手动安装（克隆仓库）

```bash
git clone https://github.com/Liyouran-center/server-load-monitor.git
cd server-load-monitor
bash install.sh --dry-run
bash install.sh
```

## 安装选项

| 选项 | 说明 |
|---|---|
| `--dry-run` | 只打印将要执行的操作，不下载、不修改任何文件或 crontab |
| `--uninstall` | 卸载（等同于运行 `uninstall.sh`） |
| `--prefix DIR` | 程序安装目录 |
| `--interval N` | cron 执行间隔（分钟，1–59，默认 5） |
| `--ref REF` | 下载的分支名或 commit SHA（默认 `main`） |
| `-h, --help` | 显示帮助 |

示例：每 1 分钟执行一次，并安装到自定义目录：

```bash
bash install.sh --interval 1 --prefix /opt/bin
```

安装脚本只会访问 `codeload.github.com` 下载仓库源码，不执行其他网络请求。

## 使用

```bash
linux-health-monitor            # 纯文本输出（普通用户时请使用完整路径 ~/.local/bin/linux-health-monitor）
linux-health-monitor --json     # 单行 JSON，便于日志系统或脚本解析
linux-health-monitor --test-notify   # 向已启用的通知渠道发送一条测试消息
linux-health-monitor --help
```

纯文本输出示例：

```text
=== linux-health-monitor | 2026-10-25 10:00:00 | web-01 | 配置: /etc/linux-health-monitor.conf ===
  指标                 当前值          阈值       状态
  load_1m                0.52               -            OK
  load_ratio             0.13            阈值 1.0   OK
  cpu_pct                12.3            阈值 90    OK
  mem_pct                61.0            阈值 90    OK
  disk:/                 45              阈值 85    OK
  zombies                0               阈值 10    OK
STATUS: OK
```

退出码：

| 退出码 | 含义 |
|---|---|
| `0` | 所有指标正常 |
| `1` | 至少一项指标超过阈值（输出包含 `ALERT`） |
| `2` | 环境不支持（非 Linux）或参数错误 |

## 配置

安装时会根据 [config.example](config.example) 生成配置文件。脚本按以下顺序查找配置：

1. 环境变量 `LHM_CONFIG` 指定的文件
2. `/etc/linux-health-monitor.conf`
3. `~/.config/linux-health-monitor.conf`

修改后无需重启，下一次 cron 执行即生效。

| 配置项 | 默认值 | 说明 |
|---|---|---|
| `CPU_WARN` | 90 | CPU 使用率告警阈值（%） |
| `MEM_WARN` | 90 | 内存真实使用率告警阈值（%） |
| `SWAP_WARN` | 80 | Swap 使用率告警阈值（%） |
| `LOAD_RATIO_WARN` | 1.0 | 负载/核心比告警阈值 |
| `DISK_WARN` | 85 | 磁盘使用率告警阈值（%） |
| `INODE_WARN` | 85 | inode 使用率告警阈值（%） |
| `ZOMBIE_WARN` | 10 | 僵尸进程数告警阈值 |
| `DISK_MOUNTS` | `/` | 需检查的挂载点，空格分隔，例如 `"/ /data /var"` |
| `CPU_SAMPLE_SECONDS` | 1 | CPU 使用率两次采样间隔（秒） |
| `NOTIFIERS` | 空 | 启用的通知渠道，空格分隔，例如 `"ntfy"`；空表示不发送通知 |
| `REMIND_INTERVAL` | 3600 | 告警持续期间的重复提醒间隔（秒），0 表示每次运行都提醒 |
| `NOTIFY_RECOVERY` | 1 | 从告警恢复为正常时是否发送恢复通知 |
| `NTFY_URL` 等 | — | ntfy 渠道的配置，见下文「通知」 |

配置文件可能包含通知令牌，安装时权限被设为 `0600`，请保持该权限。

## 通知

通知由可插拔的**通知模块**发送，模块位于 `notifiers/` 目录，安装后位于 `<PREFIX 的上级>/lib/linux-health-monitor/notifiers/`。
当前提供的模块：

| 模块 | 说明 |
|---|---|
| `ntfy` | 发送到 [ntfy](https://ntfy.sh)，支持官方服务或自建服务，支持令牌鉴权 |

### 启用 ntfy

1. 编辑配置文件，设置渠道、主题与服务地址：

   ```bash
   NOTIFIERS="ntfy"
   NTFY_URL="https://ntfy.sh"            # 或你自建的服务地址
   NTFY_TOPIC="my-server-alerts-x7k2"    # 必填；建议使用难以猜测的主题名
   NTFY_TOKEN=""                         # 私有主题或自建鉴权时填写 tk_xxxx
   ```

2. 在手机或浏览器上订阅同一个主题（ntfy 官方应用或 `https://ntfy.sh/<主题>`）。
3. 发送测试消息，确认配置正确：

   ```bash
   linux-health-monitor --test-notify
   ```

使用官方 `ntfy.sh` 的公开主题时，任何知道主题名的人都能读取消息，因此主题名要足够随机。
私有或自建服务请在 ntfy 端创建用户和令牌，并只授予该主题写权限，详见 ntfy 官方文档。

### 何时发送

| 情况 | 行为 |
|---|---|
| 出现新的告警，或告警指标发生变化 | 立即发送告警 |
| 告警持续，指标未变 | 每 `REMIND_INTERVAL` 秒提醒一次；期间不重复发送 |
| 从告警恢复为正常 | 发送恢复通知（`NOTIFY_RECOVERY=1` 时） |
| 发送失败 | 打印警告，不更新状态，下一次运行时重试 |

通知状态记录在 `/var/lib/linux-health-monitor/notify.state`（root）或 `~/.local/state/linux-health-monitor/notify.state`（普通用户）。
通知失败**不会**改变退出码：退出码仍只反映指标是否超过阈值。

### 模块接口（开发新模块）

每个模块是 `notifiers/<名称>.sh`，只需定义以下函数，然后在 `NOTIFIERS` 中加入该名称即可：

```bash
notifier_<名称>_send LEVEL TITLE BODY   # 必需；LEVEL 为 alert | recovery | test，返回 0 表示成功
notifier_<名称>_validate                # 可选；检查配置是否有效
```

模块由 `monitor.sh` 以 `source` 方式加载，应只定义函数和默认值（`: "${VAR:=默认值}"`），不要在加载时执行命令。
令牌等敏感信息请通过 `curl -K <(...)` 传入，避免出现在进程参数中。

## cron 与日志

安装后 crontab 中会出现两行（`crontab -l` 可查看）：

```cron
# linux-health-monitor
*/5 * * * * /usr/local/bin/linux-health-monitor >> /var/log/linux-health-monitor.log 2>&1
```

脚本的退出码会被 cron 忽略，因此请通过日志中的 `STATUS:` 行或 `--json` 输出的 `"status"` 字段判断健康状态。
日志不会自动轮转，长期运行时请配置 `logrotate`。

## 验证

```bash
crontab -l                                        # 应能看到上面的两行
/usr/local/bin/linux-health-monitor; echo "exit=$?"   # 立即运行一次
tail -n 20 /var/log/linux-health-monitor.log      # 查看 cron 写入的日志
```

普通用户安装时，把路径替换为 `~/.local/bin/linux-health-monitor` 和 `~/.local/state/linux-health-monitor.log`。

## 卸载

```bash
bash uninstall.sh                 # 移除 cron 条目、程序与通知模块，保留配置、日志和通知状态
bash uninstall.sh --purge         # 同时删除配置文件、日志和通知状态
```

或者在安装脚本上使用 `--uninstall`：

```bash
curl -fsSL https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/main/install.sh | bash -s -- --uninstall
```

卸载只删除程序文件，不会删除 `~/.local/bin` 等目录本身。

## 仓库文件说明

| 文件 | 作用 |
|---|---|
| `monitor.sh` | 主监控脚本：采集指标、判断阈值、输出文本或 JSON，按配置发送通知，并以退出码反映健康状态 |
| `notifiers/ntfy.sh` | ntfy 通知模块 |
| `install.sh` | 安装脚本：通过 HTTPS 下载仓库源码，安装程序、通知模块与配置，并添加 cron 条目；支持 `--dry-run` |
| `uninstall.sh` | 卸载脚本：移除 cron 条目、程序与通知模块；`--purge` 时同时删除配置、日志与状态 |
| `config.example` | 阈值、挂载点与通知配置示例，安装时复制为正式配置文件 |
| `README.md` | 本文档：安装、使用、配置说明 |
| `SECURITY.md` | 安全说明：`curl \| bash` 的风险与缓解措施 |

## 常见问题

- **`ALERT` 一直出现**：先看 `linux-health-monitor` 的输出确认是哪一项，再根据服务器实际情况调整配置文件中的阈值。
- **某项显示 `n/a`**：该指标在当前系统上无法采集，例如挂载点不存在、`free` 不可用。脚本会继续运行。
- **cron 没有输出**：检查 `crontab -l`，并确认 cron 服务已启动（`systemctl status cron` 或 `crond`）。
- **没有收到通知**：先运行 `linux-health-monitor --test-notify`。常见原因：`NTFY_TOPIC` 未设置或格式不对、`NTFY_TOKEN` 不是 `tk_` 开头、服务地址不可达、手机端没有订阅同一个主题。
- **告警后没有再次提醒**：这是正常行为。告警未变化时只在 `REMIND_INTERVAL` 到期后提醒一次。
- **安装时报 `crontab` 未找到**：请先安装 cron（见上文系统要求）。
- **想修改 cron 间隔**：先 `uninstall.sh`，再用 `--interval` 重新安装。

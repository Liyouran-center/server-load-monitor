# 安全说明

本文档说明 linux-health-monitor 的安装方式可能带来的风险，以及建议的缓解措施。

## 1. `curl | bash` 的风险

一行命令安装：

```bash
curl -fsSL https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/main/install.sh | bash
```

这种方式会直接把远程脚本交给 shell 执行，存在以下风险：

- **代码未经审查**：脚本在执行前你无法看到它的内容，任何恶意或错误的修改都会立即生效。
- **仓库被篡改**：如果仓库维护者账号被盗，或分支被恶意提交，`main` 分支上的内容会在下一次安装时被使用。
- **网络中途被篡改**：脚本使用 HTTPS 下载，可以防止大多数中间人攻击，但无法防止源头被修改。
- **下载不完整**：网络中断时，`bash` 可能只执行了前半段脚本。本项目的 `install.sh` 使用 `curl -f` 与完整的 tarball 下载，并在下载失败时立即退出，以降低此风险。
- **以 root 执行**：若以 root 身份运行，脚本可以修改系统级文件（`/usr/local/bin`、`/etc`、`/var/log`）和 root 的 crontab。

## 2. 推荐做法：先下载、审查、再执行

```bash
# 1. 下载脚本到本地
curl -fsSL https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/main/install.sh -o install.sh

# 2. 审查脚本内容
less install.sh

# 3. 查看将要执行的所有操作（不修改系统）
bash install.sh --dry-run

# 4. 确认无误后执行
bash install.sh
```

审查时建议重点检查：

- 是否只访问了 `codeload.github.com`（`install.sh` 中唯一的网络请求）；
- 是否只写入 `--dry-run` 输出中列出的路径；
- crontab 中添加的内容是否符合预期。

## 3. 固定版本（推荐用于生产环境）

默认的 `main` 分支会随时间变化。你可以固定到某个已审查的 commit SHA：

```bash
SHA=<你审查过的 40 位 commit SHA>
curl -fsSL "https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/${SHA}/install.sh" -o install.sh
less install.sh
bash install.sh --ref "$SHA"
```

`install.sh` 的 `--ref` 同时接受分支名和 40 位 commit SHA。使用 SHA 时，下载的源码与你审查的版本一致。

## 4. 脚本本身采取的措施

- **HTTPS 强制**：下载使用 `curl --proto '=https' --tlsv1.2`，不接受 HTTP 或其他协议。
- **参数校验**：仓库名、分支名、cron 间隔在使用前都会做字符集检查，防止注入。
- **路径校验**：安装路径中包含空白或 `%` 字符时会拒绝执行，因为 cron 无法正确解析这些字符。
- **临时目录清理**：下载与解压都在 `mktemp` 创建的临时目录中进行，`EXIT`、`INT`、`TERM` 信号时都会删除。
- **不修改已有配置**：如果配置文件已存在，安装脚本会保留它，不会覆盖。
- **不重复添加 cron**：如果 crontab 中已有本项目的标记行，安装脚本不会再次添加。
- **dry-run 模式**：`--dry-run` 不下载、不写文件、不修改 crontab。
- **默认不需要 root**：普通用户运行时，所有文件都安装在用户目录下。

## 5. 配置文件的风险

`monitor.sh` 会以 shell 语法 `source` 配置文件（`/etc/linux-health-monitor.conf`、`~/.config/linux-health-monitor.conf`，或 `LHM_CONFIG` 指定的文件）。这意味着：

- 配置文件中的任何命令都会以运行 `monitor.sh` 的用户身份执行。
- **请只写 `KEY=VALUE` 形式的赋值**，不要写入命令或代码。
- 建议权限：配置文件设为 `0600`（安装脚本默认如此），并且属主为运行 `monitor.sh` 的用户（root 安装时为 `root:root`）。配置中可能包含通知令牌，因此不要设为全局可读。
- 配置文件中可能保存通知渠道的访问令牌（`NTFY_TOKEN`）。请只使用权限受限的令牌（仅对目标主题有写权限），并定期轮换。

## 6. 通知模块的风险

启用通知后，`monitor.sh` 会向你配置的服务发送 HTTP 请求。

- **主题可被猜测**：公开的 ntfy.sh 主题任何知道名称的人都能读取。请使用随机的主题名，或使用私有服务。
- **令牌保护**：`notifiers/ntfy.sh` 通过 `curl -K <(...)` 传递令牌，令牌不会出现在 `ps` 等进程参数列表中；但它仍然保存在配置文件里，因此文件权限必须限制。
- **消息内容**：告警消息包含主机名、时间、指标名称与数值，不包含进程列表或文件内容。请确认该信息可以发送到你选择的服务。
- **仅允许 HTTP(S)**：`NTFY_URL` 只接受 `https://` 或 `http://` 开头；若使用 `http://`，令牌会以明文传输，请只在可信内网中使用。
- **通知失败不影响采集**：通知失败只会打印警告，不会改变退出码，也不会阻止监控运行。

## 7. 运行时的风险

- `monitor.sh` 只读取系统指标，**不会**修改系统状态。未启用通知时，它不发起任何网络请求。
- cron 以 `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` 运行脚本，脚本内部也显式设置了该 PATH，因此不会依赖调用者的环境变量。
- 日志文件（`linux-health-monitor.log`）会持续增长，请配置 `logrotate`，并注意日志中可能包含主机名与磁盘挂载点等信息。

## 8. 卸载

```bash
bash uninstall.sh --dry-run      # 查看将要删除的内容
bash uninstall.sh                # 移除 cron 条目、程序与通知模块
bash uninstall.sh --purge        # 同时删除配置文件（含令牌）、日志与通知状态
```

卸载脚本只删除 crontab 中带有本项目标记（`# linux-health-monitor`）的行，以及紧随其后的任务行，不会修改 crontab 中的其他条目。
若需要彻底移除令牌，请使用 `--purge`，或手动删除配置文件，并在 ntfy 端吊销该令牌。

## 9. 报告安全问题

如果你发现了安全问题，请通过 GitHub 的私下渠道（Security Advisory）或直接联系仓库维护者，不要在公开 Issue 中披露细节。

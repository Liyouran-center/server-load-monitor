#!/usr/bin/env bash
#================================================================
# load-monitor 一键安装脚本
#
# 支持环境变量或命令行参数两种方式自定义,所有选项均可选,
# 带默认值。优先级:命令行参数 > 环境变量 > 默认值。
#
# 一行安装示例:
#   curl -fsSL https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/main/install.sh | sudo bash -s -- \
#     --ntfy-url https://ntfy.example.com --ntfy-topic server-load-alert --api-key tk_xxxx \
#     --load-threshold 1.5 --cpu-threshold 90 --mem-threshold 90 \
#     --install-dir /opt/load-monitor --log-dir /var/log/load_monitor --retention 7 --top-n 5
#
# 等价的纯环境变量写法(推荐用 sudo env,避免密钥出现在命令行参数中):
#   curl -fsSL https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/main/install.sh \
#     | sudo env NTFY_URL=https://ntfy.example.com NTFY_TOPIC=server-load-alert NTFY_API_KEY=tk_xxxx bash
#
# 卸载:
#   curl -fsSL https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/main/install.sh \
#     | sudo bash -s -- --uninstall
#================================================================
set -euo pipefail

# 仓库原始文件地址(通过管道运行时,用于下载 load_monitor.sh)
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/main}"

#------------------ 默认值(可被参数/环境变量覆盖) ------------------
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-server-load-alert}"
NTFY_API_KEY="${NTFY_API_KEY:-}"
LOAD_THRESHOLD="${LOAD_THRESHOLD:-1.5}"
CPU_THRESHOLD="${CPU_THRESHOLD:-90}"
MEM_THRESHOLD="${MEM_THRESHOLD:-90}"
INSTALL_DIR="${INSTALL_DIR:-/opt/load-monitor}"
LOG_DIR="${LOG_DIR:-/var/log/load_monitor}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TOP_N="${TOP_N:-5}"
UNINSTALL=0
#-------------------------------------------------------------------

CONF_FILE="/etc/load_monitor.conf"
CRON_TAG="# load-monitor"

usage() {
    cat <<'EOF'
用法: install.sh [选项]

  --ntfy-url URL        ntfy 服务器地址           (默认 https://ntfy.sh)
  --ntfy-topic TOPIC    ntfy 主题                 (默认 server-load-alert)
  --api-key KEY         ntfy 访问令牌             (默认空,不推送)
  --load-threshold N    load1/核数 阈值           (默认 1.5)
  --cpu-threshold N     CPU 使用率%阈值           (默认 90)
  --mem-threshold N     内存使用率%阈值           (默认 90)
  --install-dir DIR     程序安装目录              (默认 /opt/load-monitor)
  --log-dir DIR         日志根目录                (默认 /var/log/load_monitor)
  --retention N         归档保留天数              (默认 7)
  --top-n N             高负载时抓取的进程数      (默认 5)
  --uninstall           卸载(保留日志目录)
  -h, --help            显示本帮助

优先级:命令行参数 > 环境变量 > 默认值。
EOF
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ntfy-url)        NTFY_URL="$2"; shift 2 ;;
        --ntfy-topic)      NTFY_TOPIC="$2"; shift 2 ;;
        --api-key)         NTFY_API_KEY="$2"; shift 2 ;;
        --load-threshold)  LOAD_THRESHOLD="$2"; shift 2 ;;
        --cpu-threshold)   CPU_THRESHOLD="$2"; shift 2 ;;
        --mem-threshold)   MEM_THRESHOLD="$2"; shift 2 ;;
        --install-dir)     INSTALL_DIR="$2"; shift 2 ;;
        --log-dir)         LOG_DIR="$2"; shift 2 ;;
        --retention)       RETENTION_DAYS="$2"; shift 2 ;;
        --top-n)           TOP_N="$2"; shift 2 ;;
        --uninstall)       UNINSTALL=1; shift ;;
        -h|--help)         usage 0 ;;
        *) echo "未知参数: $1" >&2; usage 1 ;;
    esac
done

# ---------- 基础检查 ----------
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 需要 root 权限,请使用 sudo 运行" >&2
    exit 1
fi

if [ "$UNINSTALL" -eq 0 ]; then
    for cmd in crontab curl awk gzip nproc top ps; do
        command -v "$cmd" >/dev/null 2>&1 || {
            echo "错误: 缺少依赖命令 '$cmd',请先安装(Debian/Ubuntu: apt install cron curl procps gawk gzip coreutils)" >&2
            exit 1
        }
    done
fi

# ---------- 卸载 ----------
if [ "$UNINSTALL" -eq 1 ]; then
    if [ -z "$INSTALL_DIR" ] || [ "$INSTALL_DIR" = "/" ]; then
        echo "错误: 拒绝删除目录 '$INSTALL_DIR'" >&2
        exit 1
    fi
    echo "==> 卸载 load-monitor"
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab - 2>/dev/null || true
    fi
    rm -f "$CONF_FILE"
    rm -rf "$INSTALL_DIR"
    echo "    已移除 cron 任务、配置文件和程序目录($INSTALL_DIR)"
    echo "    日志目录 $LOG_DIR 保留,如需删除请手动执行: rm -rf $LOG_DIR"
    exit 0
fi

# ---------- 参数校验 ----------
for v in LOAD_THRESHOLD CPU_THRESHOLD MEM_THRESHOLD RETENTION_DAYS TOP_N; do
    eval "case \"\$$v\" in ''|*[!0-9.]*) echo \"错误: $v 必须是数字,当前值为 '\$$v'\" >&2; exit 1;; esac"
done
if [ -z "$NTFY_API_KEY" ]; then
    echo "警告: 未提供 NTFY_API_KEY(--api-key),告警将无法推送(仅记录日志)" >&2
fi

# ---------- 定位 load_monitor.sh ----------
# 本地运行(git clone 后执行)时使用同目录下的文件;
# 通过 curl | bash 运行时没有同目录文件,从仓库下载。
SRC_FILE="${BASH_SOURCE[0]:-}"
SCRIPT_SRC=""
if [ -n "$SRC_FILE" ] && [ -f "$SRC_FILE" ] && [ -f "$(dirname "$SRC_FILE")/load_monitor.sh" ]; then
    SCRIPT_SRC="$(cd "$(dirname "$SRC_FILE")" && pwd)/load_monitor.sh"
else
    echo "==> 从仓库下载 load_monitor.sh"
    SCRIPT_SRC="$(mktemp)"
    trap 'rm -f "$SCRIPT_SRC"' EXIT
    curl -fsSL "$REPO_RAW/load_monitor.sh" -o "$SCRIPT_SRC"
fi

# ---------- 安装 ----------
echo "==> 安装 load-monitor 到 $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$LOG_DIR"
install -m 0755 "$SCRIPT_SRC" "$INSTALL_DIR/load_monitor.sh"

echo "==> 写入配置文件 $CONF_FILE"
cat > "$CONF_FILE" <<EOF
# load-monitor 配置(由 install.sh 生成,修改后无需重启 cron,下次执行即生效)
NTFY_URL="$NTFY_URL"
NTFY_TOPIC="$NTFY_TOPIC"
NTFY_API_KEY="$NTFY_API_KEY"
LOAD_PER_CORE_THRESHOLD=$LOAD_THRESHOLD
CPU_PERCENT_THRESHOLD=$CPU_THRESHOLD
MEM_PERCENT_THRESHOLD=$MEM_THRESHOLD
BASE_DIR="$LOG_DIR"
HISTORY_DAYS=$RETENTION_DAYS
TOP_N=$TOP_N
EOF
chmod 0600 "$CONF_FILE"

echo "==> 安装 cron 任务(每分钟记录 / 每小时打包)"
CRON_LINES="* * * * * $INSTALL_DIR/load_monitor.sh record >> $LOG_DIR/cron.log 2>&1 $CRON_TAG
0 * * * * $INSTALL_DIR/load_monitor.sh pack >> $LOG_DIR/cron.log 2>&1 $CRON_TAG"
( crontab -l 2>/dev/null | grep -v "$CRON_TAG"; echo "$CRON_LINES" ) | crontab -

echo "==> 验证"
"$INSTALL_DIR/load_monitor.sh" record
tail -n 1 "$LOG_DIR"/load_*.log

echo ""
echo "安装完成!"
echo "  配置:   $CONF_FILE"
echo "  日志:   $LOG_DIR"
echo "  测试:   $INSTALL_DIR/load_monitor.sh pack"
echo "  卸载:   重新运行 install.sh 并加 --uninstall"

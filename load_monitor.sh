#!/usr/bin/env bash
#================================================================
# load_monitor.sh — 服务器负载监控 + 每小时打包 + ntfy 告警
#
# 用法:
#   load_monitor.sh record   # 每分钟记录一次(由 crontab 调用)
#   load_monitor.sh pack     # 每小时打包一次并视情况推送 ntfy
#
# 通常由 install.sh 安装到 /opt/load-monitor 并自动配置 crontab;
# 安装时生成的 /etc/load_monitor.conf 会覆盖下方的默认值。
#
# crontab 示例:
#   * * * * * /opt/load-monitor/load_monitor.sh record >> /var/log/load_monitor/cron.log 2>&1
#   0 * * * * /opt/load-monitor/load_monitor.sh pack   >> /var/log/load_monitor/cron.log 2>&1
#================================================================

#-------------------- 配置区(默认值,可被 /etc/load_monitor.conf 覆盖) --------------------
NTFY_URL="https://ntfy.sh"              # ntfy 服务器地址(可自建)
NTFY_TOPIC="server-load-alert"          # ntfy 主题
NTFY_API_KEY=""                         # ntfy 访问令牌;为空则不带鉴权头、不推送

# 负载阈值:1 分钟平均负载 / CPU 核数 超过即视为"过高"
LOAD_PER_CORE_THRESHOLD=1.5
CPU_PERCENT_THRESHOLD=90                # CPU 使用率 %
MEM_PERCENT_THRESHOLD=90                # 内存使用率 %

BASE_DIR="/var/log/load_monitor"        # 日志根目录
HISTORY_DAYS=7                          # 归档文件保留天数
TOP_N=5                                 # 高负载时抓取的进程数
#----------------------------------------------------------------------------------------

# 若存在安装时生成的配置文件则加载(覆盖上面的默认值)
[ -f /etc/load_monitor.conf ] && . /etc/load_monitor.conf

mkdir -p "${BASE_DIR}"

# 当前小时日志文件,按小时切分,便于整点打包
cur_log()     { echo "${BASE_DIR}/load_$(date +%Y%m%d_%H).log"; }
archive_dir() { echo "${BASE_DIR}/archive/$(date +%Y%m%d)"; }

# ---------- 采集一次指标 ----------
# 输出形如: load1=0.52 load5=0.48 load15=0.40 cores=4 cpu%=12.3 mem%=45.6
collect_metrics() {
    local load1 load5 load15 cores mem_total mem_avail mem_pct cpu_idle cpu_pct
    read -r load1 load5 load15 < /proc/loadavg
    cores=$(nproc)
    mem_total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    mem_avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    mem_pct=$(awk -v t="$mem_total" -v a="$mem_avail" 'BEGIN{printf "%.1f",(t-a)*100/t}')
    cpu_idle=$(top -bn1 | awk '/%Cpu/{print $8}')
    cpu_pct=$(awk -v i="$cpu_idle" 'BEGIN{printf "%.1f",100-i}')

    echo "load1=${load1} load5=${load5} load15=${load15} cores=${cores} cpu%=${cpu_pct} mem%=${mem_pct}"
}

# ---------- 判断本次是否过高(任一指标超阈值即为过高) ----------
is_overload() {
    local m="$1" cores load_per_core
    cores=$(echo "$m" | sed -n 's/.*cores=\([0-9]*\).*/\1/p')
    load_per_core=$(echo "$m" | sed -n 's/.*load1=\([0-9.]*\).*/\1/p')
    awk -v l="$load_per_core" -v c="$cores" -v t="$LOAD_PER_CORE_THRESHOLD" \
        -v cpu="$(echo "$m" | sed -n 's/.*cpu%=\([0-9.]*\).*/\1/p')" \
        -v mem="$(echo "$m" | sed -n 's/.*mem%=\([0-9.]*\).*/\1/p')" \
        -v ct="$CPU_PERCENT_THRESHOLD" -v mt="$MEM_PERCENT_THRESHOLD" \
        'BEGIN{exit !((l/c>t)||(cpu>ct)||(mem>mt))}'
}

# ---------- 每分钟记录 ----------
do_record() {
    local log metrics ts
    log=$(cur_log)
    metrics=$(collect_metrics)
    ts=$(date '+%F %T')
    echo "[${ts}] ${metrics}" >> "$log"
    if is_overload "$metrics"; then
        {
            echo "[${ts}] === OVERLOAD: top ${TOP_N} processes by CPU ==="
            ps -eo pid,ppid,user,%cpu,%mem,etime,comm --sort=-%cpu \
                | head -n $((TOP_N + 1))
            echo ""
        } >> "$log"
    fi
}

# ---------- 每小时打包 ----------
do_pack() {
    local archive high_count peak_line msg_title msg_body archive_file prev_log
    local auth_args=()
    archive=$(archive_dir)
    mkdir -p "$archive"

    # 上一个小时的日志文件 (当前时间 -1 小时)
    prev_log="${BASE_DIR}/load_$(date -d '1 hour ago' +%Y%m%d_%H).log"
    [ -f "$prev_log" ] || return 0            # 无日志,跳过

    high_count=$(grep -c 'OVERLOAD' "$prev_log" || true)
    if [ "$high_count" -gt 0 ]; then
        peak_line=$(grep 'load1=' "$prev_log" | sort -t= -k2 -rn | head -1)
        # 标题只用 ASCII,避免非 ASCII 字符进入 HTTP 头
        msg_title="Server overload: $(hostname) (${high_count} times in past hour)"
        msg_body=$(printf '%s\n峰值: %s\n\n高负载进程快照(最近一条):\n%s\n\n日志已归档: %s' \
            "$(date '+%F %T')" "$peak_line" \
            "$(grep -A $((TOP_N + 2)) 'OVERLOAD' "$prev_log" | tail -n $((TOP_N + 2)))" \
            "$(basename "$prev_log")")
        # 仅在配置了 API Key 时才带鉴权头
        [ -n "$NTFY_API_KEY" ] && auth_args=(-H "Authorization: Bearer ${NTFY_API_KEY}")
        curl -s -m 15 "${auth_args[@]}" -H "Title: ${msg_title}" \
             -H "Priority: high" -H "Tags: warning" \
             -d "$msg_body" "${NTFY_URL}/${NTFY_TOPIC}" || true
    fi
    # 该小时内无过高情况:只打包,不推送

    # gzip 打包并清理源文件
    archive_file="${archive}/$(basename "$prev_log").gz"
    gzip -c "$prev_log" > "$archive_file" && rm -f "$prev_log"

    # 清理过期归档与残留的原始日志
    find "${BASE_DIR}/archive" -type f -name '*.gz' -mtime +"${HISTORY_DAYS}" -delete
    find "${BASE_DIR}" -maxdepth 1 -type f -name 'load_*.log' -mtime +1 -delete
}

case "${1:-}" in
    record) do_record ;;
    pack)   do_pack ;;
    *)      echo "usage: $0 {record|pack}" >&2; exit 1 ;;
esac

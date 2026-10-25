#!/usr/bin/env bash
#================================================================
# linux-health-monitor — 轻量级 Linux 服务器健康检查
#
# 采集项: 负载 (1/5/15 分钟)、负载/核心比、CPU 使用率、内存真实使用率
#         (已排除缓存与缓冲区)、Swap、磁盘空间与 inode、开机时长与启动时间、
#         进程总数与僵尸进程数。
#
# 用法:
#   monitor.sh            纯文本输出（默认）
#   monitor.sh --json     单行 JSON 输出，便于后续解析
#   monitor.sh --help     查看帮助
#
# 退出码:
#   0  所有指标正常
#   1  至少一项指标超过阈值（输出中包含 ALERT）
#   2  运行环境不支持（非 Linux）或参数错误
#
# 兼容 Bash 3.2：不使用关联数组、mapfile、${var,,} 等 Bash 4+ 语法。
#================================================================
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
set -f   # 挂载点列表不做通配符展开

VERSION="1.0.0"

#-------------------- 阈值配置（可被配置文件覆盖） --------------------
CPU_WARN=90                 # CPU 使用率 %
MEM_WARN=90                 # 内存真实使用率 %（已排除缓存与缓冲区）
SWAP_WARN=80                # Swap 使用率 %
LOAD_RATIO_WARN=1.0         # 1 分钟负载 / CPU 核心数
DISK_WARN=85                # 磁盘空间使用率 %
INODE_WARN=85               # 磁盘 inode 使用率 %
ZOMBIE_WARN=10              # 僵尸进程数量
DISK_MOUNTS="/"             # 检查的挂载点，空格分隔
CPU_SAMPLE_SECONDS=1        # /proc/stat 两次采样的间隔（秒）
#----------------------------------------------------------------------

CONFIG_USED=""
HOST_NAME="unknown"
ALERT_COUNT=0
REC=""
TEXT_BODY=""
JSON_METRICS=""

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

usage() {
    cat <<'EOF'
用法: monitor.sh [--json] [--help] [--version]

  --json        输出单行 JSON
  -h, --help    显示本帮助
  -V, --version 显示版本号

退出码: 0 正常 / 1 有指标超过阈值 / 2 环境不支持或参数错误
配置文件查找顺序: $LHM_CONFIG → /etc/linux-health-monitor.conf → ~/.config/linux-health-monitor.conf
EOF
}

# is_uint 字符串：是否为非负整数
is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *)           return 0 ;;
    esac
}

# exceeds 值 阈值：值严格大于阈值时返回 0
exceeds() {
    awk -v v="$1" -v t="$2" 'BEGIN { exit !(v + 0 > t + 0) }'
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# 读取配置文件：LHM_CONFIG → /etc → ~/.config，取第一个存在的文件。
# 配置文件是 shell 语法，请只放 KEY=VALUE；权限建议 root 所有、仅 root 可写（见 SECURITY.md）。
load_config() {
    local f
    for f in "${LHM_CONFIG:-}" "/etc/linux-health-monitor.conf" "${HOME:-/nonexistent}/.config/linux-health-monitor.conf"; do
        if [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ]; then
            . "$f"
            CONFIG_USED="$f"
            return 0
        fi
    done
}

# add 键 值 阈值 类型    （类型: n = 数字, s = 字符串；阈值为空表示不告警）
add() {
    REC="${REC}$1|$2|$3|$4"$'\n'
}

#---------------------------- 采集 ----------------------------

collect_loadavg() {
    local l1 l5 l15 cores ratio
    read -r l1 l5 l15 _ < /proc/loadavg || true

    cores=$(nproc 2>/dev/null) || cores=""
    if ! is_uint "$cores" || [ "$cores" -eq 0 ]; then
        cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cores=""
    fi
    if ! is_uint "$cores" || [ "$cores" -eq 0 ]; then
        cores=1
    fi

    ratio=$(awk -v l="${l1:-0}" -v c="$cores" 'BEGIN { printf "%.2f", l / c }')

    add load_1m  "${l1:-0}"  "" n
    add load_5m  "${l5:-0}"  "" n
    add load_15m "${l15:-0}" "" n
    add cores    "$cores"    "" n
    add load_ratio "$ratio"  "$LOAD_RATIO_WARN" n
}

# 从 /proc/stat 读取一次累计计数，输出 "忙碌滴答数 总滴答数"
cpu_counters() {
    awk '/^cpu / {
        idle = $5 + $6; total = 0
        for (i = 2; i <= NF; i++) total += $i
        printf "%d %d\n", total - idle, total
    }' /proc/stat
}

collect_cpu() {
    local s1 s2 pct
    pct=-1

    # 优先：/proc/stat 两次采样计算（不依赖 top 的输出格式，cron 下稳定）
    s1=$(cpu_counters 2>/dev/null) || s1=""
    sleep "$CPU_SAMPLE_SECONDS" 2>/dev/null || true
    s2=$(cpu_counters 2>/dev/null) || s2=""
    if [ -n "$s1" ] && [ -n "$s2" ]; then
        pct=$(awk -v a="$s1" -v b="$s2" 'BEGIN {
            split(a, x, " "); split(b, y, " ")
            dt = y[2] - x[2]; db = y[1] - x[1]
            if (dt > 0) printf "%.1f", db * 100 / dt; else printf "-1"
        }') || pct=-1
    fi

    # 回退：top -bn1 批处理模式
    if [ "$pct" = "-1" ]; then
        pct=$(top -bn1 2>/dev/null | awk '/%?Cpu/ {
            gsub(/,/, " ")
            for (i = 2; i <= NF; i++)
                if ($i == "id") { printf "%.1f", 100 - $(i - 1); exit }
        }') || true
        is_uint "${pct%%.*}" || pct=-1
        [ -n "$pct" ] || pct=-1
    fi

    add cpu_pct "$pct" "$CPU_WARN" n
}

collect_memory() {
    local out total avail mem_pct
    # 使用 free -m；存在 available 列时以其计算“真实使用率”，否则回退到 /proc/meminfo
    out=$(free -m 2>/dev/null | awk '
        /available/ { for (i = 1; i <= NF; i++) if ($i == "available") col = i }
        /^Mem:/     { print $2, (col ? $col : "") }') || out=""
    set -- $out
    total=${1:-0}
    avail=${2:-}
    if ! is_uint "$avail" && [ -r /proc/meminfo ]; then
        avail=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo) || avail=""
    fi

    if is_uint "$total" && [ "$total" -gt 0 ] && is_uint "$avail"; then
        mem_pct=$(awk -v t="$total" -v a="$avail" 'BEGIN { printf "%.1f", (t - a) * 100 / t }')
    else
        mem_pct=-1
    fi

    add mem_total_mb "$total" "" n
    add mem_pct "$mem_pct" "$MEM_WARN" n
}

collect_swap() {
    local out total used pct
    out=$(free -m 2>/dev/null | awk '/^Swap:/ { print $2, $3 }') || out=""
    if [ -z "$out" ]; then
        pct=-1
    else
        set -- $out
        total=${1:-0}
        used=${2:-0}
        if is_uint "$total" && is_uint "$used"; then
            if [ "$total" -gt 0 ]; then
                pct=$(awk -v t="$total" -v u="$used" 'BEGIN { printf "%.1f", u * 100 / t }')
            else
                pct=0   # 未配置 Swap，记为 0%
            fi
        else
            pct=-1
        fi
    fi
    add swap_pct "$pct" "$SWAP_WARN" n
}

# df_pct 选项 挂载点 → 输出使用率百分比（整数），失败输出 -1
df_pct() {
    local out
    out=$(df "$1" "$2" 2>/dev/null | awk 'NR == 2 { print $5 }') || out=""
    out=${out%\%}
    if is_uint "$out"; then
        printf '%s' "$out"
    else
        printf '%s' "-1"
    fi
}

collect_disks() {
    local m
    for m in $DISK_MOUNTS; do
        add "disk:$m"  "$(df_pct -P "$m")"  "$DISK_WARN"  n
        add "inode:$m" "$(df_pct -iP "$m")" "$INODE_WARN" n
    done
}

collect_uptime() {
    local secs human now boot
    secs=0
    read -r secs _ < /proc/uptime || true
    secs=${secs%.*}
    is_uint "$secs" || secs=0

    human=$(awk -v s="$secs" 'BEGIN {
        printf "%dd %dh %dm", s / 86400, (s % 86400) / 3600, (s % 3600) / 60
    }')
    now=$(date +%s)
    boot=$(date -d "@$((now - secs))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || boot="unknown"

    add uptime_seconds "$secs" "" n
    add uptime "$human" "" s
    add boot_time "$boot" "" s
}

collect_processes() {
    local total zombies
    total=$(ps -e -o pid= 2>/dev/null | awk 'END { print NR }') || total=-1
    zombies=$(ps -e -o stat= 2>/dev/null | awk '/Z/ { n++ } END { print n + 0 }') || zombies=-1

    add processes "$total"  "" n
    add zombies   "$zombies" "$ZOMBIE_WARN" n
}

#---------------------------- 输出 ----------------------------

# 遍历采集记录，生成文本与 JSON 片段，并统计告警数
render() {
    local key value warn type alert disp status thr json_val json_thr json_alert

    TEXT_BODY=""
    JSON_METRICS=""
    ALERT_COUNT=0

    while IFS='|' read -r key value warn type; do
        [ -n "$key" ] || continue
        [ -n "$value" ] || value=-1

        alert=0
        if [ "$type" = n ] && [ -n "$warn" ] && [ "$value" != "-1" ] && exceeds "$value" "$warn"; then
            alert=1
            ALERT_COUNT=$((ALERT_COUNT + 1))
        fi

        if [ "$type" = n ] && [ "$value" = "-1" ]; then
            disp="n/a"; status="N/A"
        elif [ "$alert" -eq 1 ]; then
            disp="$value"; status="ALERT"
        else
            disp="$value"; status="OK"
        fi

        if [ -n "$warn" ]; then thr="阈值 $warn"; else thr="-"; fi
        TEXT_BODY="${TEXT_BODY}$(printf '  %-22s %-18s %-12s %s' "$key" "$disp" "$thr" "$status")"$'\n'

        if [ "$type" = s ]; then
            json_val="\"$(json_escape "$value")\""
        elif [ "$value" = "-1" ]; then
            json_val="null"
        else
            json_val="$value"
        fi
        if [ -n "$warn" ]; then json_thr="$warn"; else json_thr="null"; fi
        if [ "$alert" -eq 1 ]; then json_alert=true; else json_alert=false; fi

        if [ -n "$JSON_METRICS" ]; then JSON_METRICS="${JSON_METRICS},"; fi
        JSON_METRICS="${JSON_METRICS}\"$(json_escape "$key")\":{\"value\":${json_val},\"threshold\":${json_thr},\"alert\":${json_alert}}"
    done <<< "$REC"
}

print_text() {
    printf '=== linux-health-monitor | %s | %s | 配置: %s ===\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$HOST_NAME" "${CONFIG_USED:-内置默认值}"
    printf '  %-22s %-18s %-12s %s\n' "指标" "当前值" "阈值" "状态"
    printf '%s' "$TEXT_BODY"
    if [ "$ALERT_COUNT" -gt 0 ]; then
        printf 'STATUS: ALERT（%d 项超过阈值）\n' "$ALERT_COUNT"
    else
        printf 'STATUS: OK\n'
    fi
}

print_json() {
    local status="ok"
    if [ "$ALERT_COUNT" -gt 0 ]; then status="alert"; fi
    printf '{"timestamp":"%s","host":"%s","status":"%s","alerts":%d,"metrics":{%s}}\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(json_escape "$HOST_NAME")" "$status" "$ALERT_COUNT" "$JSON_METRICS"
}

#---------------------------- 主流程 ----------------------------

main() {
    local json=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)              json=1 ;;
            -h|--help)           usage; exit 0 ;;
            -V|--version)        printf 'linux-health-monitor %s\n' "$VERSION"; exit 0 ;;
            *)                   printf '未知参数: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done

    if [ ! -r /proc/loadavg ]; then
        die "未找到 /proc/loadavg，本脚本仅支持 Linux，已中止以免输出误导性数据"
    fi

    load_config
    HOST_NAME=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)

    collect_loadavg
    collect_cpu
    collect_memory
    collect_swap
    collect_disks
    collect_uptime
    collect_processes

    render

    if [ "$json" -eq 1 ]; then
        print_json
    else
        print_text
    fi

    if [ "$ALERT_COUNT" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main "$@"

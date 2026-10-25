#!/usr/bin/env bash
#================================================================
# linux-health-monitor — 轻量级 Linux 服务器健康检查
#
# 采集项: 负载 (1/5/15 分钟)、负载/核心比、CPU 使用率、内存真实使用率
#         (已排除缓存与缓冲区)、Swap、磁盘空间与 inode、开机时长与启动时间、
#         进程总数与僵尸进程数。
#
# 用法:
#   monitor.sh                纯文本输出（默认）
#   monitor.sh --json         单行 JSON 输出，便于后续解析
#   monitor.sh --test-notify  向已配置的通知渠道发送一条测试消息
#   monitor.sh --help         查看帮助
#
# 退出码:
#   0  所有指标正常
#   1  至少一项指标超过阈值（输出中包含 ALERT）
#   2  运行环境不支持（非 Linux）或参数错误
#
# 通知: 告警与恢复通知由可插拔的通知模块发送，模块位于 notifiers/ 目录，
#       通过 NOTIFIERS 配置启用。通知失败不会改变退出码。
#
# 兼容 Bash 3.2：不使用关联数组、mapfile、${var,,} 等 Bash 4+ 语法。
#================================================================
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
set -f   # 挂载点与通知渠道列表不做通配符展开

VERSION="1.1.0"
SCRIPT_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd)

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

#-------------------- 通知配置（可被配置文件覆盖） --------------------
NOTIFIERS=""                # 启用的通知渠道，空格分隔，例如 "ntfy"；留空则不发送
NOTIFY_RECOVERY=1           # 从告警恢复为正常时是否发送恢复通知（1 是 / 0 否）
REMIND_INTERVAL=3600        # 告警持续期间的重复提醒间隔（秒）；0 表示每次运行都提醒
#----------------------------------------------------------------------

CONFIG_USED=""
HOST_NAME="unknown"
ALERT_COUNT=0
ALERT_KEYS=""               # 本次告警的指标键，空格分隔（用于判断是否变化）
ALERT_LINES=""              # 本次告警的可读明细
REC=""
TEXT_BODY=""
JSON_METRICS=""

NOTIFIER_DIR=""
NOTIFY_ACTIVE=""            # 实际加载成功的通知渠道
STATE_DIR=""
STATE_FILE=""
LAST_STATUS="ok"
LAST_KEYS=""
LAST_SENT=0

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

usage() {
    cat <<'EOF'
用法: monitor.sh [--json] [--test-notify] [--help] [--version]

  --json          输出单行 JSON
  --test-notify   向已配置的通知渠道发送一条测试消息，然后退出
  -h, --help      显示本帮助
  -V, --version   显示版本号

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
# 配置文件是 shell 语法，请只放 KEY=VALUE；权限建议 0600（可能包含通知令牌，见 SECURITY.md）。
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

# 遍历采集记录，生成文本与 JSON 片段，统计告警数并记录告警明细
render() {
    local key value warn type alert disp status thr json_val json_thr json_alert

    TEXT_BODY=""
    JSON_METRICS=""
    ALERT_COUNT=0
    ALERT_KEYS=""
    ALERT_LINES=""

    while IFS='|' read -r key value warn type; do
        [ -n "$key" ] || continue
        [ -n "$value" ] || value=-1

        alert=0
        if [ "$type" = n ] && [ -n "$warn" ] && [ "$value" != "-1" ] && exceeds "$value" "$warn"; then
            alert=1
            ALERT_COUNT=$((ALERT_COUNT + 1))
            ALERT_KEYS="${ALERT_KEYS}${ALERT_KEYS:+ }${key}"
            ALERT_LINES="${ALERT_LINES}  - ${key}: ${value}（阈值 ${warn}）"$'\n'
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

#---------------------------- 通知 ----------------------------

# 查找通知模块目录：LHM_NOTIFIER_DIR → 安装后的 lib 目录 → 仓库内 notifiers/
resolve_notifier_dir() {
    local d
    for d in "${LHM_NOTIFIER_DIR:-}" \
             "$SCRIPT_DIR/../lib/linux-health-monitor/notifiers" \
             "$SCRIPT_DIR/notifiers"; do
        if [ -n "$d" ] && [ -d "$d" ]; then
            NOTIFIER_DIR="$d"
            return 0
        fi
    done
    NOTIFIER_DIR=""
}

# 按 NOTIFIERS 加载通知模块。每个模块必须定义 notifier_<名称>_send。
load_notifiers() {
    local name file
    NOTIFY_ACTIVE=""
    for name in $NOTIFIERS; do
        case "$name" in
            ''|*[!a-z0-9_]*)
                warn "忽略非法的通知渠道名: $name"
                continue ;;
        esac
        file="${NOTIFIER_DIR:-/nonexistent}/$name.sh"
        if [ ! -r "$file" ]; then
            warn "找不到通知模块 $name（查找目录: ${NOTIFIER_DIR:-未找到}）"
            continue
        fi
        . "$file"
        if ! type "notifier_${name}_send" >/dev/null 2>&1; then
            warn "通知模块 $name 未定义 notifier_${name}_send"
            continue
        fi
        NOTIFY_ACTIVE="${NOTIFY_ACTIVE} ${name}"
    done
}

# dispatch 级别 标题 正文：依次调用所有已加载的通知渠道；任一失败则返回 1
dispatch() {
    local name rc=0
    for name in $NOTIFY_ACTIVE; do
        if ! "notifier_${name}_send" "$1" "$2" "$3"; then
            warn "通知渠道 ${name} 发送失败（级别: $1）"
            rc=1
        fi
    done
    return "$rc"
}

# 状态文件记录上一次的通知状态，用于去重和恢复通知
resolve_state_dir() {
    if [ -n "${LHM_STATE_DIR:-}" ]; then
        STATE_DIR="$LHM_STATE_DIR"
    elif [ "$(id -u)" -eq 0 ]; then
        STATE_DIR="/var/lib/linux-health-monitor"
    elif [ -n "${HOME:-}" ]; then
        STATE_DIR="$HOME/.local/state/linux-health-monitor"
    else
        STATE_DIR=""
    fi
    if [ -n "$STATE_DIR" ]; then
        STATE_FILE="$STATE_DIR/notify.state"
    else
        STATE_FILE=""
    fi
}

read_state() {
    local k v
    LAST_STATUS="ok"
    LAST_KEYS=""
    LAST_SENT=0
    if [ -n "$STATE_FILE" ] && [ -r "$STATE_FILE" ]; then
        while IFS='=' read -r k v; do
            case "$k" in
                status) LAST_STATUS="$v" ;;
                keys)   LAST_KEYS="$v" ;;
                sent)   LAST_SENT="$v" ;;
            esac
        done < "$STATE_FILE"
    fi
    case "$LAST_STATUS" in ok|alert) ;; *) LAST_STATUS="ok" ;; esac
    is_uint "$LAST_SENT" || LAST_SENT=0
}

# write_state 状态 键列表 发送时间（先写临时文件再替换，避免半写入）
write_state() {
    local tmp="$STATE_FILE.tmp.$$"
    [ -n "$STATE_FILE" ] || return 0
    if ! mkdir -p -- "$STATE_DIR" 2>/dev/null; then
        warn "无法创建状态目录: $STATE_DIR"
        return 0
    fi
    if ! { printf 'status=%s\n' "$1"; printf 'keys=%s\n' "$2"; printf 'sent=%s\n' "$3"; } > "$tmp" 2>/dev/null; then
        warn "无法写入状态文件: $tmp"
        return 0
    fi
    mv -- "$tmp" "$STATE_FILE"
}

# 根据本次结果决定是否发送通知
#   - 新增告警、告警指标变化、或超过重复提醒间隔：发送告警
#   - 从告警恢复为正常：发送恢复通知（若 NOTIFY_RECOVERY=1）
# 发送失败时不更新状态，下一次运行会重试。
notify_if_needed() {
    local now title body

    [ -n "$NOTIFY_ACTIVE" ] || return 0
    is_uint "$REMIND_INTERVAL" || REMIND_INTERVAL=3600

    resolve_state_dir
    read_state
    now=$(date +%s)

    if [ "$ALERT_COUNT" -gt 0 ]; then
        if [ "$LAST_STATUS" != "alert" ] \
           || [ "$LAST_KEYS" != "$ALERT_KEYS" ] \
           || [ $((now - LAST_SENT)) -ge "$REMIND_INTERVAL" ]; then
            title="ALERT ${HOST_NAME}: ${ALERT_COUNT} item(s) over threshold"
            body=$(printf '主机: %s\n时间: %s\n超过阈值的指标:\n%s' \
                "$HOST_NAME" "$(date '+%Y-%m-%d %H:%M:%S')" "$ALERT_LINES")
            if dispatch alert "$title" "$body"; then
                write_state alert "$ALERT_KEYS" "$now"
            fi
        fi
    elif [ "$LAST_STATUS" = "alert" ]; then
        title="RECOVERED ${HOST_NAME}"
        body=$(printf '主机: %s\n时间: %s\n所有指标已恢复正常。' \
            "$HOST_NAME" "$(date '+%Y-%m-%d %H:%M:%S')")
        if [ "$NOTIFY_RECOVERY" != "1" ] || dispatch recovery "$title" "$body"; then
            write_state ok "" "$now"
        fi
    fi
}

#---------------------------- 主流程 ----------------------------

main() {
    local json=0 test_notify=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --json)              json=1 ;;
            --test-notify)       test_notify=1 ;;
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

    resolve_notifier_dir
    load_notifiers

    if [ "$test_notify" -eq 1 ]; then
        [ -n "$NOTIFY_ACTIVE" ] || die "没有可用的通知渠道，请检查配置中的 NOTIFIERS"
        if dispatch test "TEST linux-health-monitor ${HOST_NAME}" \
            "这是一条测试通知。时间: $(date '+%Y-%m-%d %H:%M:%S')"; then
            printf '测试通知已发送（渠道:%s）\n' "$NOTIFY_ACTIVE"
            exit 0
        fi
        printf '测试通知发送失败\n' >&2
        exit 1
    fi

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

    notify_if_needed

    if [ "$ALERT_COUNT" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main "$@"

#!/usr/bin/env bash
#================================================================
# linux-health-monitor 卸载脚本
#
# 移除内容:
#   - 当前用户 crontab 中由本项目添加的条目（标记行 + 紧随其后的任务行）
#   - 程序文件 <PREFIX>/linux-health-monitor
# 默认保留配置文件与日志；加 --purge 时一并删除。
#
# 用法:
#   uninstall.sh [--dry-run] [--prefix DIR] [--purge]
#================================================================
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

PROG_NAME="linux-health-monitor"
CRON_MARKER="# linux-health-monitor"

DRY_RUN=0
PURGE=0
PREFIX=""
BIN_PATH=""
CONFIG_PATH=""
LOG_FILE=""

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: uninstall.sh [选项]

  --dry-run        只打印将要执行的操作，不做任何修改
  --prefix DIR     程序所在目录（需与安装时一致）
  --purge          同时删除配置文件与日志文件
  -h, --help       显示本帮助
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --purge)   PURGE=1 ;;
            --prefix)  [ $# -ge 2 ] || die "--prefix 需要一个目录参数"; PREFIX="$2"; shift ;;
            -h|--help) usage; exit 0 ;;
            *)         die "未知参数: $1（使用 --help 查看用法）" ;;
        esac
        shift
    done
}

resolve_paths() {
    if [ "$(id -u)" -eq 0 ]; then
        [ -n "$PREFIX" ] || PREFIX=/usr/local/bin
        CONFIG_PATH=/etc/linux-health-monitor.conf
        LOG_FILE=/var/log/linux-health-monitor.log
    else
        : "${HOME:?HOME 未设置，请用 --prefix 指定程序目录}"
        [ -n "$PREFIX" ] || PREFIX="$HOME/.local/bin"
        CONFIG_PATH="$HOME/.config/linux-health-monitor.conf"
        LOG_FILE="$HOME/.local/state/linux-health-monitor.log"
    fi
    BIN_PATH="$PREFIX/$PROG_NAME"
}

# 删除 crontab 中的标记行，以及紧随其后的本项目任务行
remove_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        say "未找到 crontab 命令，跳过 cron 清理"
        return 0
    fi

    local current filtered
    current=$(crontab -l 2>/dev/null || true)

    if ! grep -qF -- "$CRON_MARKER" <<< "$current"; then
        say "crontab 中没有 linux-health-monitor 条目，跳过"
        return 0
    fi

    filtered=$(awk -v m="$CRON_MARKER" -v p="$PROG_NAME" '
        skip == 1 { skip = 0; if (index($0, p) > 0) next }
        $0 == m   { skip = 1; next }
        { print }
    ' <<< "$current")

    if [ "$DRY_RUN" -eq 1 ]; then
        say "[dry-run] 从 crontab 移除 linux-health-monitor 标记行及其后的任务行"
        return 0
    fi

    if [ -n "$filtered" ]; then
        printf '%s\n' "$filtered" | crontab -
    else
        crontab -r
    fi
    say "已移除 cron 条目"
}

# remove_path 路径 说明
remove_path() {
    local p="$1" label="$2"
    if [ ! -e "$p" ]; then
        say "不存在，跳过${label}: $p"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        say "[dry-run] 删除${label}: $p"
        return 0
    fi
    rm -f -- "$p"
    say "已删除${label}: $p"
}

main() {
    parse_args "$@"
    resolve_paths

    say "=== linux-health-monitor 卸载 ==="
    remove_cron
    remove_path "$BIN_PATH" "程序"

    if [ "$PURGE" -eq 1 ]; then
        remove_path "$CONFIG_PATH" "配置文件"
        remove_path "$LOG_FILE" "日志文件"
    else
        say "保留配置文件与日志（如需一并删除，请加 --purge）:"
        say "  $CONFIG_PATH"
        say "  $LOG_FILE"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        say "dry-run 完成，未做任何修改。"
    else
        say "卸载完成。"
    fi
}

main "$@"

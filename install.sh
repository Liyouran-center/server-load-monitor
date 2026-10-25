#!/usr/bin/env bash
#================================================================
# linux-health-monitor 安装脚本
#
# 一行安装（推荐先阅读 SECURITY.md，并使用"先下载、审查、再执行"的方式）:
#   curl -fsSL https://raw.githubusercontent.com/Liyouran-center/server-load-monitor/main/install.sh | bash
#
# 常用选项:
#   --dry-run        只打印将要执行的操作，不下载、不修改任何文件或 crontab
#   --uninstall      卸载（使用本地 uninstall.sh，或下载后执行仓库中的 uninstall.sh）
#   --prefix DIR     程序安装目录（默认: root 为 /usr/local/bin，普通用户为 ~/.local/bin）
#   --interval N     cron 执行间隔，单位分钟，取值 1–59（默认 5）
#   --ref REF        要下载的分支名或 40 位 commit SHA（默认 main）
#   -h, --help       显示帮助
#
# 环境变量（用于 fork 或测试）:
#   LHM_REPO_OWNER   仓库所有者（默认 Liyouran-center）
#   LHM_REPO_NAME    仓库名称（默认 server-load-monitor）
#   LHM_REF          同 --ref
#================================================================
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

PROG_NAME="linux-health-monitor"
CRON_MARKER="# linux-health-monitor"

REPO_OWNER="${LHM_REPO_OWNER:-Liyouran-center}"
REPO_NAME="${LHM_REPO_NAME:-server-load-monitor}"
REPO_REF="${LHM_REF:-main}"
DRY_RUN=0
UNINSTALL=0
PREFIX=""
INTERVAL=5
TMP_DIR=""

BIN_PATH=""
CONFIG_PATH=""
LOG_FILE=""
LIB_DIR=""
NOTIFIER_DST=""

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: install.sh [选项]

  --dry-run        只打印将要执行的操作，不做任何修改
  --uninstall      卸载程序、cron 条目（保留配置与日志）
  --prefix DIR     程序安装目录（默认 root: /usr/local/bin；普通用户: ~/.local/bin）
  --interval N     cron 执行间隔，单位分钟，1–59（默认 5）
  --ref REF        下载的分支名或 commit SHA（默认 main）
  -h, --help       显示本帮助

环境变量 LHM_REPO_OWNER / LHM_REPO_NAME / LHM_REF 可覆盖仓库来源（用于 fork）。
EOF
}

# 清理临时目录；EXIT / INT / TERM 时都会执行
cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf -- "$TMP_DIR"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)   DRY_RUN=1 ;;
            --uninstall) UNINSTALL=1 ;;
            --prefix)    [ $# -ge 2 ] || die "--prefix 需要一个目录参数"; PREFIX="$2"; shift ;;
            --interval)  [ $# -ge 2 ] || die "--interval 需要一个数字参数"; INTERVAL="$2"; shift ;;
            --ref)       [ $# -ge 2 ] || die "--ref 需要一个分支名或 SHA"; REPO_REF="$2"; shift ;;
            -h|--help)   usage; exit 0 ;;
            *)           die "未知参数: $1（使用 --help 查看用法）" ;;
        esac
        shift
    done
}

validate() {
    case "$REPO_OWNER$REPO_NAME" in
        *[!A-Za-z0-9._-]*) die "仓库所有者或名称包含非法字符" ;;
    esac
    case "$REPO_REF" in
        ''|*[!A-Za-z0-9._/-]*) die "--ref 包含非法字符" ;;
    esac
    case "$INTERVAL" in
        ''|*[!0-9]*) die "--interval 必须是 1–59 之间的整数" ;;
    esac
    if [ "$INTERVAL" -lt 1 ] || [ "$INTERVAL" -gt 59 ]; then
        die "--interval 必须是 1–59 之间的整数"
    fi
}

# 根据当前用户确定安装路径
resolve_paths() {
    local is_root=0
    if [ "$(id -u)" -eq 0 ]; then
        is_root=1
    fi

    if [ "$is_root" -eq 1 ]; then
        [ -n "$PREFIX" ] || PREFIX=/usr/local/bin
        CONFIG_PATH=/etc/linux-health-monitor.conf
        LOG_FILE=/var/log/linux-health-monitor.log
    else
        : "${HOME:?HOME 未设置，请用 --prefix 指定安装目录}"
        [ -n "$PREFIX" ] || PREFIX="$HOME/.local/bin"
        CONFIG_PATH="$HOME/.config/linux-health-monitor.conf"
        LOG_FILE="$HOME/.local/state/linux-health-monitor.log"
    fi
    BIN_PATH="$PREFIX/$PROG_NAME"
    # 通知模块安装到 <PREFIX 的上级>/lib/linux-health-monitor/notifiers
    LIB_DIR="$(dirname -- "$PREFIX")/lib/$PROG_NAME"
    NOTIFIER_DST="$LIB_DIR/notifiers"
}

# cron 不能正确处理包含空白或 % 的路径
check_cron_safe() {
    local p
    for p in "$BIN_PATH" "$LOG_FILE"; do
        case "$p" in
            *[[:space:]]*|*%*)
                die "路径包含空白或 % 字符，cron 无法正确解析: $p" ;;
        esac
    done
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        if [ "$DRY_RUN" -eq 1 ]; then
            warn "未找到命令: $1（dry-run 继续，正式安装前需要先安装）"
            return 0
        fi
        die "缺少命令: $1，请先安装后重试"
    fi
}

# 确保目录存在且可写（dry-run 只打印）
ensure_dir() {
    local d="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        say "[dry-run] 确保目录存在且可写: $d"
        return 0
    fi
    mkdir -p -- "$d" || die "无法创建目录: $d"
    [ -w "$d" ] || die "目录不可写: $d（请以 root 运行，或用 --prefix 指定其他目录）"
}

archive_url() {
    if grep -qE '^[0-9a-f]{40}$' <<< "$REPO_REF"; then
        printf 'https://codeload.github.com/%s/%s/tar.gz/%s' "$REPO_OWNER" "$REPO_NAME" "$REPO_REF"
    else
        printf 'https://codeload.github.com/%s/%s/tar.gz/refs/heads/%s' "$REPO_OWNER" "$REPO_NAME" "$REPO_REF"
    fi
}

# 通过 HTTPS 下载仓库 tarball 到临时目录并解压
fetch_source() {
    local url
    url=$(archive_url)
    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lhm.XXXXXX") || die "无法创建临时目录"
    mkdir -p -- "$TMP_DIR/src"
    say "下载源码: $url"
    curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP_DIR/src.tar.gz" -- "$url" \
        || die "下载失败，请检查网络，或确认 --ref 是否存在"
    tar -xzf "$TMP_DIR/src.tar.gz" -C "$TMP_DIR/src" --strip-components=1 \
        || die "解压失败"
}

install_program() {
    ensure_dir "$PREFIX"
    if [ "$DRY_RUN" -eq 1 ]; then
        say "[dry-run] 安装 monitor.sh -> $BIN_PATH（权限 0755）"
        return 0
    fi
    [ -f "$TMP_DIR/src/monitor.sh" ] || die "仓库中缺少 monitor.sh"
    cp -- "$TMP_DIR/src/monitor.sh" "$BIN_PATH"
    chmod 0755 -- "$BIN_PATH"
    say "已安装程序: $BIN_PATH"
}

# 安装通知模块（notifiers/*.sh），monitor.sh 会从这里加载
install_notifiers() {
    ensure_dir "$NOTIFIER_DST"
    if [ "$DRY_RUN" -eq 1 ]; then
        say "[dry-run] 安装通知模块 notifiers/*.sh -> $NOTIFIER_DST（权限 0644）"
        return 0
    fi
    local f count=0
    for f in "$TMP_DIR/src/notifiers/"*.sh; do
        [ -f "$f" ] || continue
        cp -- "$f" "$NOTIFIER_DST/"
        chmod 0644 -- "$NOTIFIER_DST/$(basename -- "$f")"
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || die "仓库中缺少通知模块 notifiers/*.sh"
    say "已安装通知模块（${count} 个）到: $NOTIFIER_DST"
}

install_config() {
    if [ -e "$CONFIG_PATH" ]; then
        say "配置文件已存在，保留不变: $CONFIG_PATH"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        say "[dry-run] 若配置文件不存在，则由 config.example 生成: $CONFIG_PATH"
        return 0
    fi
    ensure_dir "$(dirname -- "$CONFIG_PATH")"
    if [ -f "$TMP_DIR/src/config.example" ]; then
        cp -- "$TMP_DIR/src/config.example" "$CONFIG_PATH"
        # 配置中可能保存通知令牌，只允许所有者读写
        chmod 0600 -- "$CONFIG_PATH"
        say "已生成配置文件: $CONFIG_PATH"
    else
        warn "仓库中没有 config.example，跳过配置文件生成（将使用内置默认阈值）"
    fi
}

prepare_log() {
    ensure_dir "$(dirname -- "$LOG_FILE")"
    if [ "$DRY_RUN" -eq 1 ]; then
        say "[dry-run] 创建日志文件（若不存在）: $LOG_FILE"
        return 0
    fi
    if [ ! -e "$LOG_FILE" ]; then
        : > "$LOG_FILE"
    fi
}

install_cron() {
    need_cmd crontab
    local entry current
    entry="*/${INTERVAL} * * * * ${BIN_PATH} >> ${LOG_FILE} 2>&1"
    current=$(crontab -l 2>/dev/null || true)

    if grep -qF -- "$CRON_MARKER" <<< "$current"; then
        say "crontab 中已存在 linux-health-monitor 条目，跳过添加（如需修改间隔，请先执行 --uninstall）"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        say "[dry-run] 向当前用户 crontab 追加以下两行（保留原有条目）:"
        say "    $CRON_MARKER"
        say "    $entry"
        return 0
    fi

    {
        if [ -n "$current" ]; then
            printf '%s\n' "$current"
        fi
        printf '%s\n' "$CRON_MARKER" "$entry"
    } | crontab -
    say "已添加 cron 条目（每 ${INTERVAL} 分钟执行一次）"
}

print_summary() {
    say ""
    if [ "$DRY_RUN" -eq 1 ]; then
        say "dry-run 完成：以上是将要执行的操作，未修改任何文件或 crontab。"
    else
        say "安装完成。"
    fi
    say ""
    say "安装内容:"
    say "  程序 : $BIN_PATH"
    say "  配置 : $CONFIG_PATH"
    say "  cron : */${INTERVAL} * * * * ${BIN_PATH} >> ${LOG_FILE} 2>&1"
    say "  日志 : $LOG_FILE"
    say "  模块 : $NOTIFIER_DST"
    say ""
    say "验证方法:"
    say "  crontab -l                     # 查看定时任务"
    say "  $BIN_PATH                      # 立即运行一次（退出码 0=正常 1=告警 2=环境错误）"
    say "  tail -n 20 $LOG_FILE           # 查看 cron 写入的日志"
    say ""
    say "启用通知（默认关闭）:"
    say "  1. 编辑 $CONFIG_PATH"
    say "     设置 NOTIFIERS=\"ntfy\"，并填写 NTFY_TOPIC（以及私有服务所需的 NTFY_TOKEN）"
    say "  2. $BIN_PATH --test-notify     # 发送一条测试通知"
}

do_install() {
    need_cmd curl
    need_cmd tar
    check_cron_safe

    say "=== linux-health-monitor 安装: ${REPO_OWNER}/${REPO_NAME} @ ${REPO_REF} ==="
    if [ "$DRY_RUN" -eq 1 ]; then
        say "模式: dry-run（不会下载，也不会修改系统）"
        say "将下载: $(archive_url)"
    else
        fetch_source
    fi

    install_program
    install_notifiers
    install_config
    prepare_log
    install_cron
    print_summary
}

do_uninstall() {
    local script=""
    # 若是直接运行本地仓库中的 install.sh，则优先使用同目录的 uninstall.sh
    if [ -f "$0" ] && [ "$(basename -- "$0")" = "install.sh" ] && [ -f "$(dirname -- "$0")/uninstall.sh" ]; then
        script="$(dirname -- "$0")/uninstall.sh"
    fi

    if [ -z "$script" ] && [ "$DRY_RUN" -eq 1 ]; then
        say "[dry-run] 将下载 ${REPO_OWNER}/${REPO_NAME} @ ${REPO_REF}，并执行其中的 uninstall.sh"
        say "[dry-run] 移除 cron 条目，并删除 $BIN_PATH（保留配置与日志）"
        return 0
    fi

    if [ -z "$script" ]; then
        fetch_source
        script="$TMP_DIR/src/uninstall.sh"
    fi
    [ -f "$script" ] || die "找不到 uninstall.sh"

    if [ "$DRY_RUN" -eq 1 ]; then
        bash "$script" --dry-run --prefix "$PREFIX"
    else
        bash "$script" --prefix "$PREFIX"
    fi
}

main() {
    parse_args "$@"
    validate
    resolve_paths

    if [ "$UNINSTALL" -eq 1 ]; then
        do_uninstall
    else
        do_install
    fi
}

main "$@"

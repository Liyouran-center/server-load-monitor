#!/usr/bin/env bash
#================================================================
# 通知模块: ntfy  (https://ntfy.sh，或自建的 ntfy 服务)
#
# 本文件由 monitor.sh 以 source 方式加载，不能单独执行。
#
# 模块接口（所有通知模块都需遵循）:
#   notifier_<名称>_send LEVEL TITLE BODY
#       LEVEL  alert | recovery | test
#       返回 0 表示发送成功；非 0 表示失败。失败时 monitor.sh 会打印警告，
#       并且不更新状态，下一次运行会重新尝试发送。
#   notifier_<名称>_validate            （可选）检查配置是否有效
#
# 启用方式（配置文件）:
#   NOTIFIERS="ntfy"
#   NTFY_URL="https://ntfy.sh"          服务地址，可指向自建服务
#   NTFY_TOPIC="server-load-alert"      主题：仅允许 A-Z a-z 0-9 _ -，最长 64 字符
#   NTFY_TOKEN="tk_xxxxxxxx"            访问令牌（私有主题或开启鉴权时需要）
#   NTFY_PRIORITY_ALERT=4               告警优先级 1–5
#   NTFY_PRIORITY_RECOVERY=3            恢复通知优先级 1–5
#
# 安全说明：令牌通过 curl 的配置输入（进程替换）传递，不会出现在进程参数列表中。
#================================================================

# 仅在未设置时提供默认值，不覆盖配置文件中的取值
: "${NTFY_URL:=https://ntfy.sh}"
: "${NTFY_TOPIC:=}"
: "${NTFY_TOKEN:=}"
: "${NTFY_PRIORITY_ALERT:=4}"
: "${NTFY_PRIORITY_RECOVERY:=3}"

notifier_ntfy_validate() {
    local url="$NTFY_URL" topic="$NTFY_TOPIC" token="$NTFY_TOKEN"

    case "$url" in
        https://?*|http://?*) ;;
        *)
            echo "ntfy: NTFY_URL 必须以 https:// 或 http:// 开头" >&2
            return 1 ;;
    esac

    if [ -z "$topic" ] || [ "${#topic}" -gt 64 ]; then
        echo "ntfy: NTFY_TOPIC 未设置，或超过 64 个字符" >&2
        return 1
    fi
    case "$topic" in
        *[!A-Za-z0-9_-]*)
            echo "ntfy: NTFY_TOPIC 只能包含字母、数字、_ 和 -" >&2
            return 1 ;;
    esac

    if [ -n "$token" ]; then
        case "$token" in
            tk_*) ;;
            *)
                echo "ntfy: NTFY_TOKEN 格式不正确（应以 tk_ 开头）" >&2
                return 1 ;;
        esac
        case "$token" in
            *[!A-Za-z0-9_]*)
                echo "ntfy: NTFY_TOKEN 包含非法字符" >&2
                return 1 ;;
        esac
    fi

    case "$NTFY_PRIORITY_ALERT" in
        [1-5]) ;;
        *) echo "ntfy: NTFY_PRIORITY_ALERT 必须是 1–5" >&2; return 1 ;;
    esac
    case "$NTFY_PRIORITY_RECOVERY" in
        [1-5]) ;;
        *) echo "ntfy: NTFY_PRIORITY_RECOVERY 必须是 1–5" >&2; return 1 ;;
    esac

    return 0
}

notifier_ntfy_send() {
    local level="$1" title="$2" body="$3"
    local prio tags safe_title url auth

    notifier_ntfy_validate || return 1

    case "$level" in
        alert)    prio="$NTFY_PRIORITY_ALERT";    tags="warning" ;;
        recovery) prio="$NTFY_PRIORITY_RECOVERY"; tags="white_check_mark" ;;
        *)        prio=3;                         tags="bell" ;;
    esac

    # HTTP 头只能使用可打印的 ASCII；同时去掉引号和反斜杠，避免破坏 curl 配置
    safe_title=$(printf '%s' "$title" | LC_ALL=C tr -cd '\40-\176' | tr -d '"\\')
    url="${NTFY_URL%/}/${NTFY_TOPIC}"

    auth=""
    if [ -n "$NTFY_TOKEN" ]; then
        auth=$(printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN")
    fi

    # 请求头通过 -K 的进程替换传入：令牌不出现在 ps 输出中
    printf '%s' "$body" | curl -fsS --max-time 15 --retry 2 -o /dev/null \
        -K <(printf 'header = "Title: %s"\nheader = "Priority: %s"\nheader = "Tags: %s"\n%s' \
                "$safe_title" "$prio" "$tags" "$auth") \
        --data-binary @- -- "$url"
}

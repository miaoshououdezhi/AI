#!/usr/bin/env bash
# Common functions; sourcing this file has no filesystem or service side effects.
export XM_PRODUCT=xray-manager
export XM_DEFAULT_CORE_VERSION=v26.3.27
XM_ROOT=${XM_ROOT:-}
XM_HOME="${XM_ROOT}/opt/xray-manager"
XM_ETC="${XM_ROOT}/etc/xray-manager"
XM_DATA="${XM_ROOT}/var/lib/xray-manager"
XM_LOG="${XM_ROOT}/var/log/xray-manager"
XM_BIN="$XM_HOME/bin/xray"
XM_STATE="$XM_ETC/state.json"
XM_CONFIG="$XM_ETC/config.json"
XM_EXTRA_BIN="$XM_HOME/bin/sing-box"
XM_EXTRA_CONFIG="$XM_ETC/extra.json"
XM_TEMP_DIR=
XM_LOCK_FD=
XM_YES=0

xm_message() { printf '%s[%s] %s%s\n' "$1" "$2" "$3" "${XM_UI_RESET:-}" >&2; }
xm_info() { xm_message "${XM_UI_CYAN:-}" 信息 "$*"; }
xm_success() { xm_message "${XM_UI_GREEN:-}" 成功 "$*"; }
xm_ok() { xm_message "${XM_UI_GREEN:-}" OK "$*"; }
xm_warning() { xm_message "${XM_UI_YELLOW:-}" 警告 "$*"; }
xm_error() { xm_message "${XM_UI_RED:-}" 错误 "$*"; }
xm_pause() {
    [[ -t 0 && -t 2 ]] || return 0
    printf '\n%s[信息]%s 按任意键返回%s…' "$XM_UI_CYAN" "$XM_UI_RESET" "${1:-主菜单}" >&2
    IFS= read -r -s -n 1 || true
    printf '\n' >&2
}
xm_require_root() {
    if [[ -z $XM_ROOT && $EUID -ne 0 ]]; then xm_error '请使用 root 或 sudo 运行。'; return 1; fi
    if [[ -n $XM_ROOT && ( $XM_ROOT != /* || $XM_ROOT == / || $XM_ROOT == */ || $XM_ROOT == *'/../'* || $XM_ROOT == */.. || $XM_ROOT == *'/./'* ) ]]; then
        xm_error 'XM_ROOT 必须是隔离测试的绝对目录，不能含 . 或 .. 路径段。'; return 1
    fi
}
xm_need_commands() {
    local cmd
    for cmd in "$@"; do command -v "$cmd" >/dev/null 2>&1 || { xm_error "缺少命令：$cmd"; return 1; }; done
}
xm_yes() { [[ ${1,,} == y || ${1,,} == yes ]]; }
xm_confirm() {
    local reply
    [[ $XM_YES == 1 ]] && return 0
    [[ -t 0 ]] || { xm_error '非交互模式需要 --yes 明确确认。'; return 2; }
    printf '%s [输入 y/yes 确认，不区分大小写]：' "$1" >&2
    IFS= read -r reply || return 2
    xm_yes "$reply" || { xm_info '已取消。'; return 2; }
}
# Terminal styling is enabled only for interactive stderr. Any NO_COLOR presence
# disables styling, including NO_COLOR=""; TERM=dumb is always plain text.
# UI_GREEN/YELLOW are consumed by the entrypoint status renderer.
export XM_UI_WHITE='' XM_UI_BLUE='' XM_UI_RED='' XM_UI_CYAN='' XM_UI_GREEN='' XM_UI_YELLOW='' XM_UI_BOLD='' XM_UI_RESET=''
xm_ui_init() {
    XM_UI_WHITE=; XM_UI_BLUE=; XM_UI_RED=; XM_UI_CYAN=; XM_UI_GREEN=; XM_UI_YELLOW=; XM_UI_BOLD=; XM_UI_RESET=
    if [[ -t 2 && ! ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]]; then
        XM_UI_WHITE=$'\033[38;2;255;255;255m'
        XM_UI_BLUE=$'\033[38;2;0;191;255m'; XM_UI_CYAN=$'\033[38;2;0;255;255m'; XM_UI_GREEN=$'\033[38;2;0;255;0m'
        XM_UI_RED=$'\033[38;2;255;0;0m'; XM_UI_YELLOW=$XM_UI_BLUE
        XM_UI_BOLD=$XM_UI_BLUE; XM_UI_RESET=$'\033[0m'
    fi
}
xm_terminal_width() {
    local width=${COLUMNS:-} terminal_size
    if [[ $width =~ ^[1-9][0-9]{0,3}$ ]]; then printf '%s\n' "$width"; return 0; fi
    if [[ -t 2 ]] && terminal_size=$(stty size <&2 2>/dev/null) && [[ $terminal_size =~ ^[0-9]+[[:space:]]+([1-9][0-9]{0,3})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '80\n'
    fi
}
xm_ui_heading() { printf '\n%s%s%s\n\n' "$XM_UI_CYAN" "$1" "$XM_UI_RESET" >&2; }
xm_ui_item() { printf '%s[%s]  %s%s%s\n' "$XM_UI_BLUE" "$1" "$XM_UI_WHITE" "$2" "$XM_UI_RESET" >&2; }
xm_ui_pair() {
    # Left labels are fixed four-character Chinese captions, followed by a
    # generous column gap. User strings are never accepted as menu captions.
    local number_gap=''
    [[ ${#1} -gt 1 ]] || number_gap=' '
    printf '%s[%s] %s %s%s          %s[%s]  %s%s%s\n' "$XM_UI_BLUE" "$1" "$number_gap" "$XM_UI_WHITE" "$2" "$XM_UI_BLUE" "$3" "$XM_UI_WHITE" "$4" "$XM_UI_RESET" >&2
}
xm_input_safe() {
    # read removes the newline; reject terminal control characters before using
    # input in prompts or diagnostics. Protocol validation remains authoritative.
    [[ ! $1 =~ [[:cntrl:]] ]]
}
xm_read() {
    local variable=$1 prompt=$2 default=${3:-} display=${4:-${3:-}} reply
    [[ $variable =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 1
    while :; do
        if [[ -n $display ]]; then printf '%s%s%s [%s%s%s]：' "$XM_UI_CYAN" "$prompt" "$XM_UI_RESET" "$XM_UI_GREEN" "$display" "$XM_UI_RESET" >&2; else printf '%s%s：%s' "$XM_UI_CYAN" "$prompt" "$XM_UI_RESET" >&2; fi
        IFS= read -r reply || return 2
        [[ $reply != :q ]] || { xm_info '已取消。'; return 2; }
        if ! xm_input_safe "$reply"; then xm_error '输入不能含终端控制字符，请重新输入。'; continue; fi
        [[ -n $reply ]] || reply=$default
        printf -v "$variable" '%s' "$reply"
        return 0
    done
}
xm_read_secret() {
    local variable=$1 prompt=$2 default=${3:-} reply
    [[ $variable =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 1
    while :; do
        printf '%s%s [回车使用随机默认值，隐藏]：%s' "$XM_UI_CYAN" "$prompt" "$XM_UI_RESET" >&2
        IFS= read -r -s reply || { printf '\n' >&2; return 2; }
        printf '\n' >&2
        [[ $reply != :q ]] || { xm_info '已取消。'; return 2; }
        if ! xm_input_safe "$reply"; then xm_error '秘密不能含控制字符，请重新输入。'; continue; fi
        [[ -n $reply ]] || reply=$default
        printf -v "$variable" '%s' "$reply"
        return 0
    done
}
xm_lock() {
    [[ -z $XM_LOCK_FD ]] || return 0
    [[ -d $XM_ETC && ! -L $XM_ETC && ! -L $XM_ETC/.manager.lock ]] || { xm_error '受管目录或锁文件不安全。'; return 1; }
    (umask 077; : >> "$XM_ETC/.manager.lock") || return 1
    exec {XM_LOCK_FD}>"$XM_ETC/.manager.lock" || return 1
    flock -n "$XM_LOCK_FD" || { xm_error '另一项管理操作正在执行，请稍后重试。'; exec {XM_LOCK_FD}>&-; XM_LOCK_FD=; return 1; }
}
xm_unlock() {
    if [[ -n $XM_LOCK_FD ]]; then exec {XM_LOCK_FD}>&-; XM_LOCK_FD=; fi
}
xm_private_temp() {
    [[ -z $XM_TEMP_DIR ]] || { xm_error '事务尚未清理。'; return 1; }
    XM_TEMP_DIR=$(umask 077; mktemp -d "$XM_ETC/.transaction.XXXXXXXX") || return 1
}
xm_temp_cleanup() {
    if [[ -n $XM_TEMP_DIR && $XM_TEMP_DIR == "$XM_ETC"/.transaction.* && -d $XM_TEMP_DIR && ! -L $XM_TEMP_DIR ]]; then
        rm -rf -- "$XM_TEMP_DIR"
    fi
    XM_TEMP_DIR=
}
xm_path_no_links() {
    local path=$1
    [[ $path == /* && $path != *'/../'* && $path != */.. && $path != *'/./'* ]] || return 1
    while [[ $path != / && -n $path ]]; do
        [[ ! -L $path ]] || { xm_error "拒绝符号链接路径：$path"; return 1; }
        path=${path%/*}
        [[ -n $path ]] || path=/
    done
}
xm_atomic_copy() {
    local source=$1 destination=$2 mode=${3:-0640} temporary
    [[ -f $source ]] && xm_path_no_links "$destination" || { xm_error '拒绝不安全的文件替换。'; return 1; }
    temporary=$(umask 077; mktemp "${destination%/*}/.manager-file.XXXXXXXX") || return 1
    if ! cp -- "$source" "$temporary" || ! chmod "$mode" "$temporary"; then rm -f -- "$temporary"; return 1; fi
    if [[ -z $XM_ROOT && $EUID -eq 0 ]] && id xray-manager >/dev/null 2>&1; then
        chown root:xray-manager "$temporary" || { rm -f -- "$temporary"; return 1; }
    fi
    mv -f -- "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
}
xm_owned() { [[ -f $1/.xray-manager-owned && ! -L $1 && ! -L $1/.xray-manager-owned ]] && [[ $(cat "$1/.xray-manager-owned") == xray-manager:1 ]]; }
xm_installed() {
    xm_path_no_links "$XM_BIN" && xm_path_no_links "$XM_STATE" && xm_path_no_links "$XM_CONFIG" && xm_path_no_links "$XM_EXTRA_CONFIG" && xm_path_no_links "$XM_EXTRA_BIN" && xm_path_no_links "$XM_DATA" && xm_path_no_links "$XM_LOG" && xm_owned "$XM_HOME" && xm_owned "$XM_ETC" && [[ -x $XM_BIN && -f $XM_STATE && ! -L $XM_STATE && ! -L $XM_BIN ]] || {
        xm_error '尚未安装，或受管文件不完整；请运行 install。'; return 1;
    }
}

# Release our lock descriptor in service subprocesses so long-lived OpenRC daemons
# cannot retain the manager's lock. Function redirection is restored on return.
xm_service_call() {
    if [[ -n $XM_LOCK_FD ]]; then platform_service "$@" {XM_LOCK_FD}>&-; else platform_service "$@"; fi
}

# Extra service subprocesses also cannot retain the manager lock.
xm_extra_service_call() {
    if [[ -n $XM_LOCK_FD ]]; then platform_extra_service "$@" {XM_LOCK_FD}>&-; else platform_extra_service "$@"; fi
}

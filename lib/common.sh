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
XM_TEMP_DIR=
XM_LOCK_FD=
XM_YES=0

xm_error() { printf '错误：%s\n' "$*" >&2; }
xm_info() { printf '%s\n' "$*" >&2; }
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
xm_confirm() {
    local reply
    [[ $XM_YES == 1 ]] && return 0
    [[ -t 0 ]] || { xm_error '非交互模式需要 --yes 明确确认。'; return 2; }
    printf '%s [输入 yes 确认]：' "$1" >&2
    IFS= read -r reply || return 2
    [[ $reply == yes ]] || { xm_info '已取消。'; return 2; }
}
xm_read() {
    local variable=$1 prompt=$2 default=${3:-} reply
    [[ $variable =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 1
    if [[ -n $default ]]; then printf '%s [%s]：' "$prompt" "$default" >&2; else printf '%s：' "$prompt" >&2; fi
    IFS= read -r reply || return 2
    [[ -n $reply ]] || reply=$default
    printf -v "$variable" '%s' "$reply"
}
xm_read_secret() {
    local variable=$1 prompt=$2 reply
    [[ $variable =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 1
    printf '%s（留空自动生成）：' "$prompt" >&2
    IFS= read -r -s reply || { printf '\n' >&2; return 2; }
    printf '\n' >&2
    printf -v "$variable" '%s' "$reply"
}
xm_lock() {
    [[ -z $XM_LOCK_FD ]] || return 0
    [[ -d $XM_ETC && ! -L $XM_ETC && ! -L $XM_ETC/.manager.lock ]] || { xm_error '受管目录或锁文件不安全。'; return 1; }
    (umask 077; : >> "$XM_ETC/.manager.lock") || return 1
    exec {XM_LOCK_FD}>"$XM_ETC/.manager.lock" || return 1
    flock -n "$XM_LOCK_FD" || { xm_error '另一项管理操作正在执行，请稍后重试。'; exec {XM_LOCK_FD}>&-; XM_LOCK_FD=; return 1; }
}
xm_unlock() {
    if [[ -n $XM_LOCK_FD ]]; then flock -u "$XM_LOCK_FD"; exec {XM_LOCK_FD}>&-; XM_LOCK_FD=; fi
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
    xm_path_no_links "$XM_BIN" && xm_path_no_links "$XM_STATE" && xm_path_no_links "$XM_CONFIG" && xm_path_no_links "$XM_DATA" && xm_path_no_links "$XM_LOG" && xm_owned "$XM_HOME" && xm_owned "$XM_ETC" && [[ -x $XM_BIN && -f $XM_STATE && ! -L $XM_STATE && ! -L $XM_BIN ]] || {
        xm_error '尚未安装，或受管文件不完整；请运行 install。'; return 1;
    }
}

# Release our lock descriptor in service subprocesses so long-lived OpenRC daemons
# cannot retain the manager's lock. Function redirection is restored on return.
xm_service_call() {
    if [[ -n $XM_LOCK_FD ]]; then platform_service "$@" {XM_LOCK_FD}>&-; else platform_service "$@"; fi
}

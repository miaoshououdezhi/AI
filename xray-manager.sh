#!/usr/bin/env bash
# xray-manager: the public CLI and compact Chinese terminal interface.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf '错误：需要 Bash 4.4 或更新版本，请运行 sh install.sh。\n' >&2
    exit 1
fi
XM_CODE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
# Only fixed, adjacent library paths are loaded. State and user data are never sourced.
source "$XM_CODE_ROOT/lib/common.sh" || exit 1
source "$XM_CODE_ROOT/lib/state.sh" || exit 1
source "$XM_CODE_ROOT/lib/platform.sh" || exit 1
source "$XM_CODE_ROOT/lib/protocol.sh" || exit 1
XM_WORK_DIR=

xm_cleanup() {
    local status=$?
    state_exit_cleanup "$status"
    if [[ -n $XM_WORK_DIR && $XM_WORK_DIR == "$XM_ETC"/.work.* && -d $XM_WORK_DIR && ! -L $XM_WORK_DIR ]]; then rm -rf -- "$XM_WORK_DIR"; fi
    return "$status"
}
trap xm_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

xm_help() {
    cat <<'HELP'
xray-manager — Xray 中文交互管理

用法：bash xray-manager.sh [--yes] <命令> [参数]
无参数：打开交互菜单；help：显示本帮助。

  install [v版本]                 安装，默认 v26.3.27；重复安装保留节点
  upgrade v版本                  指定核心版本升级，保留上一版供回退
  rollback                       切换到上一版核心
  list                           列出节点（不显示秘密）
  add vless-reality ID 名称 端口 地址 SNI TARGET [UUID 私钥 公钥 ShortID]
  add trojan ID 名称 端口 地址 证书路径 私钥路径 [密码]
  add shadowsocks ID 名称 端口 地址 [密码]
  delete ID                      删除节点，需要确认或 --yes
  share ID                       显式输出含客户端秘密的分享链接
  service start|stop|restart|status|enable|disable
  logs [行数]                    显示最近日志，默认 80 行
  diagnose                       检查版本、配置和服务健康
  backup /绝对路径/备份.json      保存私密 JSON（0600），拒绝覆盖已有文件
  restore /绝对路径/备份.json     校验并恢复节点，保留当前核心版本，需确认
  uninstall                      停服务，删除本项目程序和节点，需确认

端口与地址由节点配置指定；首次安装不开放任何公网监听。
CLI 返回：0 成功，1 操作失败，2 参数错误或取消；中断 130/143。
证书私钥须允许 xray-manager 账户读取；Trojan 证书 SAN 应匹配地址。
升级/恢复会在原生校验及健康失败时回退；SIGKILL/断电需 diagnose 检查。
HELP
}
xm_usage_error() { xm_error "$*"; xm_info '运行 help 查看命令格式。'; return 2; }
xm_work_begin() {
    [[ -z $XM_WORK_DIR ]] || return 0
    XM_WORK_DIR=$(umask 077; mktemp -d "$XM_ETC/.work.XXXXXXXX") || return 1
}
xm_work_end() {
    if [[ -n $XM_WORK_DIR && $XM_WORK_DIR == "$XM_ETC"/.work.* && -d $XM_WORK_DIR && ! -L $XM_WORK_DIR ]]; then rm -rf -- "$XM_WORK_DIR"; fi
    XM_WORK_DIR=
}
xm_version_valid() { [[ $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { xm_error '版本格式必须为 v数字.数字.数字。'; return 2; }; }
xm_ready() {
    xm_require_root && xm_need_commands jq flock && platform_detect && xm_installed && xm_lock && state_validate "$XM_STATE"
}
xm_install_code() {
    local file
    [[ $XM_CODE_ROOT == "$XM_HOME" ]] && return 0
    for file in lib assets; do
        [[ ! -L $XM_HOME/$file ]] || return 1
        mkdir -p -- "$XM_HOME/$file" || return 1
        chmod 0750 "$XM_HOME/$file" || return 1
    done
    for file in xray-manager.sh install.sh lib/common.sh lib/state.sh lib/platform.sh lib/protocol.sh assets/xray-manager.service assets/xray-manager.openrc assets/xray-manager.logrotate; do
        [[ -f $XM_CODE_ROOT/$file ]] || { xm_error "程序文件缺失：$file"; return 1; }
        xm_atomic_copy "$XM_CODE_ROOT/$file" "$XM_HOME/$file" 0755 || return 1
    done
    if [[ -z $XM_ROOT ]]; then chown root:xray-manager "$XM_HOME/lib" "$XM_HOME/assets" || return 1; fi
}
xm_install() {
    local version=${1:-$XM_DEFAULT_CORE_VERSION}
    (($# <= 1)) || { xm_usage_error 'install 最多接受一个版本参数。'; return 2; }
    xm_version_valid "$version" || return $?
    xm_require_root && platform_detect && platform_dependencies && platform_prepare && xm_lock || return 1
    if [[ -f $XM_STATE ]]; then
        xm_installed && state_validate "$XM_STATE" && xm_install_code && platform_install_service || return 1
        xm_info "已安装核心 $(jq -r .core_version "$XM_STATE")；保留节点。更换核心请使用 upgrade。"
        return 0
    fi
    xm_work_begin || return 1
    platform_fetch_core "$version" "$XM_WORK_DIR/xray" || return 1
    state_empty "$version" > "$XM_WORK_DIR/state.json" || return 1
    xm_install_code && state_apply "$XM_WORK_DIR/state.json" "$XM_WORK_DIR/xray" || return 1
    if ! platform_install_service || ! xm_service_call enable || ! xm_service_call start || ! platform_health; then
        xm_service_call stop >/dev/null 2>&1 || true
        xm_service_call disable >/dev/null 2>&1 || true
        platform_remove_service >/dev/null 2>&1 || true
        rm -f -- "$XM_STATE" "$XM_CONFIG" "$XM_BIN"
        xm_error '首次启动失败，已撤销服务和初始状态；可检查日志后重新 install。'; return 1
    fi
    xm_info "安装完成：核心 $version，无公网监听。入口：$XM_HOME/xray-manager.sh"
}
xm_upgrade() {
    (($# == 1)) || { xm_usage_error 'upgrade 需要显式指定 v版本。'; return 2; }
    xm_version_valid "$1" || return $?
    xm_ready && xm_work_begin || return 1
    if [[ $(jq -r '.core_version' "$XM_STATE") == "$1" ]]; then xm_info '已经是该核心版本。'; return 0; fi
    platform_fetch_core "$1" "$XM_WORK_DIR/xray" || return 1
    jq --arg version "$1" '.core_version=$version' "$XM_STATE" > "$XM_WORK_DIR/state.json" || return 1
    state_apply "$XM_WORK_DIR/state.json" "$XM_WORK_DIR/xray" || return 1
    xm_info "核心已切换至 $1，原运行状态已保留。"
}
xm_rollback() {
    (($# == 0)) || { xm_usage_error 'rollback 不接受参数。'; return 2; }
    xm_ready && xm_work_begin || return 1
    [[ -f $XM_HOME/bin/xray.previous && ! -L $XM_HOME/bin/xray.previous && -f $XM_ETC/core.previous-version && ! -L $XM_ETC/core.previous-version ]] || { xm_error '没有可回退的上一版核心。'; return 1; }
    local version
    version=$(cat "$XM_ETC/core.previous-version")
    xm_version_valid "$version" || return 1
    cp -- "$XM_HOME/bin/xray.previous" "$XM_WORK_DIR/xray" && chmod 0755 "$XM_WORK_DIR/xray" || return 1
    jq --arg version "$version" '.core_version=$version' "$XM_STATE" > "$XM_WORK_DIR/state.json" || return 1
    state_apply "$XM_WORK_DIR/state.json" "$XM_WORK_DIR/xray" || return 1
    xm_info "核心已回退至 $version。"
}
xm_list() {
    (($# == 0)) || { xm_usage_error 'list 不接受参数。'; return 2; }
    xm_ready || return 1
    jq -r 'if (.nodes|length)==0 then "尚无节点。选择添加节点开始配置。" else "ID\t名称\t协议\t端口\t地址", (.nodes[] | [.id,.name,.type,(.port|tostring),.address] | @tsv) end' "$XM_STATE"
}
xm_add() {
    (($# >= 5)) || { xm_usage_error 'add 的参数不足。'; return 2; }
    xm_ready && xm_work_begin || return 1
    local node type=$1 id=$2 port=$4
    case $type in
        vless-reality) (($# == 7 || $# == 11)) || { xm_usage_error 'VLESS 需要 SNI TARGET，可选的 UUID/私钥/公钥/ShortID 须同时提供。'; return 2; } ;;
        trojan) (($# == 7 || $# == 8)) || { xm_usage_error 'Trojan 需要证书和私钥路径，密码可选。'; return 2; } ;;
        shadowsocks) (($# == 5 || $# == 6)) || { xm_usage_error 'Shadowsocks 密码可选。'; return 2; } ;;
        *) xm_usage_error '不支持此协议。'; return 2 ;;
    esac
    node=$(protocol_new "$@") || return 1
    jq -e --arg id "$id" --argjson port "$port" '.nodes | all(.id != $id and .port != $port)' "$XM_STATE" >/dev/null || { xm_error '节点 ID 或端口已经存在。'; return 1; }
    platform_port_available "$port" || { xm_error '该端口已被监听，请换一个端口。'; return 1; }
    jq --argjson node "$node" '.nodes += [$node]' "$XM_STATE" > "$XM_WORK_DIR/state.json" || return 1
    state_apply "$XM_WORK_DIR/state.json" || return 1
    xm_info "节点 $id 已保存。运行 share $id 查看客户端链接。"
}
xm_delete() {
    (($# == 1)) || { xm_usage_error 'delete 需要节点 ID。'; return 2; }
    xm_ready && xm_work_begin || return 1
    jq -e --arg id "$1" '.nodes | any(.id == $id)' "$XM_STATE" >/dev/null || { xm_error '节点不存在。'; return 1; }
    xm_confirm "删除节点 $1？" || return 2
    jq --arg id "$1" '.nodes |= map(select(.id != $id))' "$XM_STATE" > "$XM_WORK_DIR/state.json" || return 1
    state_apply "$XM_WORK_DIR/state.json" || return 1
    xm_info "节点 $1 已删除。"
}
xm_share() {
    (($# == 1)) || { xm_usage_error 'share 需要节点 ID。'; return 2; }
    xm_ready || return 1
    local node
    node=$(jq -ec --arg id "$1" '.nodes[] | select(.id == $id)' "$XM_STATE") || { xm_error '节点不存在。'; return 1; }
    protocol_share "$node"
}
xm_service() {
    (($# == 1)) || { xm_usage_error 'service 需要一个操作。'; return 2; }
    case $1 in start|stop|restart|status|enable|disable) ;; *) xm_usage_error '未知服务操作。'; return 2 ;; esac
    xm_ready || return 1
    if [[ $1 == start || $1 == restart ]]; then
        xm_work_begin && xm_private_temp && protocol_generate "$XM_STATE" "$XM_TEMP_DIR/check.json" && state_native_validate "$XM_BIN" "$XM_TEMP_DIR/check.json" || return 1
        # Detect direct edits to the generated file; state is the single source of truth.
        cmp -s "$XM_TEMP_DIR/check.json" "$XM_CONFIG" || { xm_error 'config.json 与状态不一致，请使用 restore 恢复配置。'; return 1; }
        xm_temp_cleanup
    fi
    xm_service_call "$1" || return 1
    if [[ $1 == start || $1 == restart ]]; then platform_health || return 1; fi
    xm_info "服务操作完成：$1"
}
xm_logs() {
    (($# <= 1)) || { xm_usage_error 'logs 最多接受一个行数。'; return 2; }
    local lines=${1:-80}
    [[ $lines =~ ^[0-9]+$ && $lines -ge 1 && $lines -le 1000 ]] || { xm_usage_error '行数必须在 1..1000。'; return 2; }
    xm_ready && platform_logs "$lines"
}
xm_diagnose() {
    (($# == 0)) || { xm_usage_error 'diagnose 不接受参数。'; return 2; }
    xm_ready && xm_work_begin && xm_private_temp || return 1
    printf '系统：%s %s | 架构：%s | init：%s\n' "$XM_OS" "$XM_OS_VERSION" "$XM_ARCH" "$XM_INIT"
    printf '状态核心：%s | 节点：%s\n' "$(jq -r .core_version "$XM_STATE")" "$(jq '.nodes|length' "$XM_STATE")"
    "$XM_BIN" version | head -n 1
    protocol_generate "$XM_STATE" "$XM_TEMP_DIR/check.json" && state_native_validate "$XM_BIN" "$XM_TEMP_DIR/check.json" || return 1
    cmp -s "$XM_TEMP_DIR/check.json" "$XM_CONFIG" || { xm_error '生成配置与活跃配置不一致。'; return 1; }
    xm_info '状态与原生配置校验通过。'
    platform_health || { xm_error '服务未运行或不健康。'; return 1; }
    xm_info '服务健康检查通过。'
}
xm_backup() {
    (($# == 1)) || { xm_usage_error 'backup 需要绝对文件路径。'; return 2; }
    [[ $1 == /* && $1 != */ ]] || { xm_usage_error '备份路径必须是绝对文件路径。'; return 2; }
    xm_ready && xm_path_no_links "$1" || return 1
    # Noclobber prevents accidental overwrite, including symlinks and existing secrets.
    (umask 077; set -o noclobber; cat "$XM_STATE" > "$1") || { xm_error '备份写入失败（目录须已存在，目标须不存在）。'; return 1; }
        xm_info "私密备份已保存：$1。请妥善保管，它包含节点私钥和密码。"
}
xm_restore() {
    (($# == 1)) || { xm_usage_error 'restore 需要备份文件路径。'; return 2; }
    xm_ready && xm_work_begin && state_validate "$1" || return 1
    xm_confirm '用备份替换全部节点？当前核心版本将保留。' || return 2
    local node port already_owned
    # Reusing the manager's existing listener is allowed; new listeners are conflict checked.
    while IFS= read -r node; do
        port=$(jq -r .port <<< "$node")
        already_owned=$(jq -r --argjson port "$port" '.nodes | any(.port==$port)' "$XM_STATE")
        if [[ $already_owned != true ]]; then platform_port_available "$port" || { xm_error "恢复端口冲突：$port"; return 1; }; fi
    done < <(jq -c '.nodes[]' "$1")
    jq --arg version "$(jq -r .core_version "$XM_STATE")" '.core_version=$version' "$1" > "$XM_WORK_DIR/state.json" || return 1
    state_apply "$XM_WORK_DIR/state.json" || return 1
    xm_info '节点已恢复，原运行状态已保留。'
}
xm_uninstall() {
    (($# == 0)) || { xm_usage_error 'uninstall 不接受参数。'; return 2; }
    xm_ready || return 1
    xm_confirm "卸载 $XM_PRODUCT 并删除全部节点与核心？独立备份和外部证书会保留。" || return 2
    local directory file
    for directory in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG"; do
        xm_owned "$directory" || { xm_error "目录缺少所有权标记，拒绝删除：$directory"; return 1; }
    done
    xm_service_call stop && xm_service_call disable && platform_remove_service || return 1
    # Explicit names only: unknown files, backups, certificates, and service account remain.
    for file in "$XM_STATE" "$XM_CONFIG" "$XM_ETC/core.previous-version" "$XM_BIN" "$XM_HOME/bin/xray.previous" "$XM_HOME/xray-manager.sh" "$XM_HOME/install.sh" "$XM_HOME/lib/common.sh" "$XM_HOME/lib/state.sh" "$XM_HOME/lib/platform.sh" "$XM_HOME/lib/protocol.sh" "$XM_HOME/assets/xray-manager.service" "$XM_HOME/assets/xray-manager.openrc" "$XM_HOME/assets/xray-manager.logrotate"; do
        [[ ! -L $file ]] || { xm_error "拒绝删除符号链接：$file"; return 1; }
        rm -f -- "$file" || return 1
    done
    xm_info '已卸载。备份、外部证书、日志与未知文件保留；使用原始源码 install 可重新安装。'
}
xm_dispatch() {
    local command=${1:-menu} result
    (($# == 0)) || shift
    case $command in
        help|-h|--help) xm_help ;;
        install) xm_install "$@" ;;
        upgrade) xm_upgrade "$@" ;;
        rollback) xm_rollback "$@" ;;
        list) xm_list "$@" ;;
        add) xm_add "$@" ;;
        delete) xm_delete "$@" ;;
        share) xm_share "$@" ;;
        service) xm_service "$@" ;;
        logs) xm_logs "$@" ;;
        diagnose) xm_diagnose "$@" ;;
        backup) xm_backup "$@" ;;
        restore) xm_restore "$@" ;;
        uninstall) xm_uninstall "$@" ;;
        menu) (($# == 0)) || return 2; xm_menu ;;
        *) xm_usage_error "未知命令：$command" ;;
    esac
    result=$?
    xm_temp_cleanup; xm_work_end; xm_unlock
    return "$result"
}
xm_menu_add() {
    local XM_CHOICE XM_ID XM_NAME XM_PORT XM_ADDRESS XM_SNI XM_TARGET XM_CERT XM_KEY XM_PASSWORD
    printf '\n添加节点\n  1 VLESS REALITY Vision\n  2 Trojan TLS（已有证书）\n  3 Shadowsocks 2022\n  0 返回\n' >&2
    xm_read XM_CHOICE '选择' || return 2
    case $XM_CHOICE in 0) return 0 ;; 1|2|3) ;; *) xm_error '选择无效。'; return 2 ;; esac
    xm_read XM_ID '节点 ID（字母/数字/短横线）' || return 2
    xm_read XM_NAME '显示名称' "$XM_ID" || return 2
    xm_read XM_PORT '监听端口' '443' || return 2
    xm_read XM_ADDRESS '服务器公网 IP 或域名（仅分享用）' || return 2
    case $XM_CHOICE in
        1)
            xm_read XM_SNI 'REALITY SNI' 'www.cloudflare.com' || return 2
            xm_read XM_TARGET 'REALITY 目标（域名:端口）' "${XM_SNI}:443" || return 2
            xm_dispatch add vless-reality "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" "$XM_SNI" "$XM_TARGET"
            ;;
        2)
            xm_info '证书 SAN 应匹配地址，服务账户须能读取私钥。'
            xm_read XM_CERT '现有证书绝对路径' || return 2
            xm_read XM_KEY '现有私钥绝对路径' || return 2
            xm_read_secret XM_PASSWORD '节点密码' || return 2
            if [[ -n $XM_PASSWORD ]]; then xm_dispatch add trojan "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" "$XM_CERT" "$XM_KEY" "$XM_PASSWORD"; else xm_dispatch add trojan "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" "$XM_CERT" "$XM_KEY"; fi
            ;;
        3)
            xm_read_secret XM_PASSWORD 'Base64 主密钥' || return 2
            if [[ -n $XM_PASSWORD ]]; then xm_dispatch add shadowsocks "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" "$XM_PASSWORD"; else xm_dispatch add shadowsocks "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS"; fi
            ;;
    esac
}
xm_menu_service() {
    local XM_CHOICE action
    printf '\n服务操作\n  1 启动   2 停止   3 重启\n  4 状态   5 开机启动   6 取消开机启动\n  0 返回\n' >&2
    xm_read XM_CHOICE '选择' || return 2
    case $XM_CHOICE in 0) return 0 ;; 1) action=start ;; 2) action=stop ;; 3) action=restart ;; 4) action=status ;; 5) action=enable ;; 6) action=disable ;; *) xm_error '选择无效。'; return 2 ;; esac
    xm_dispatch service "$action"
}
xm_menu() {
    local XM_CHOICE XM_ID XM_VERSION XM_FILE version count status width
    xm_require_root || return 1
    while :; do
        version='未安装'; count=0; status='未运行'
        if [[ -f $XM_STATE ]] && command -v jq >/dev/null 2>&1; then
            version=$(jq -r '.core_version // "未知"' "$XM_STATE" 2>/dev/null)
            count=$(jq '.nodes|length' "$XM_STATE" 2>/dev/null)
            platform_detect >/dev/null 2>&1 && xm_service_call status >/dev/null 2>&1 && status='运行中'
        fi
        width=${COLUMNS:-80}
        if [[ $width =~ ^[0-9]+$ && $width -lt 60 ]]; then printf '\n── Xray 管理 ──\n' >&2; else printf '\n────────────────────────────────────────\n  Xray 管理  |  xray-manager\n────────────────────────────────────────\n' >&2; fi
        printf '核心 %s  ·  节点 %s  ·  %s\n\n' "$version" "$count" "$status" >&2
        printf '核心管理\n  1 安装       2 升级       3 核心回退\n节点管理\n  4 列表       5 添加       6 删除       7 分享\n运行维护\n  8 服务       9 日志      10 诊断\n数据管理\n 11 备份      12 恢复      13 卸载\n\n  0 退出\n' >&2
        xm_read XM_CHOICE '选择' || { xm_info '输入结束，已退出。'; return 0; }
        case $XM_CHOICE in
            0) return 0 ;;
            1) xm_dispatch install ;;
            2) xm_read XM_VERSION '目标版本（例 v26.3.27）' && xm_dispatch upgrade "$XM_VERSION" ;;
            3) xm_dispatch rollback ;;
            4) xm_dispatch list ;;
            5) xm_menu_add ;;
            6) xm_read XM_ID '删除节点 ID' && xm_dispatch delete "$XM_ID" ;;
            7) xm_info '分享链接含客户端秘密，请勿公开。'; xm_read XM_ID '节点 ID' && xm_dispatch share "$XM_ID" ;;
            8) xm_menu_service ;;
            9) xm_dispatch logs ;;
            10) xm_dispatch diagnose ;;
            11) xm_read XM_FILE '备份绝对路径' && xm_dispatch backup "$XM_FILE" ;;
            12) xm_read XM_FILE '备份绝对路径' && xm_dispatch restore "$XM_FILE" ;;
            13) xm_dispatch uninstall ;;
            *) xm_error '选择无效，请输入菜单编号。' ;;
        esac
        # Do not clear the terminal or hide errors; EOF leaves immediately on the next prompt.
    done
}
xm_main() {
    umask 077
    if [[ ${1:-} == --yes ]]; then XM_YES=1; shift; fi
    if [[ ${1:-} == -- ]]; then shift; fi
    xm_dispatch "$@"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then xm_main "$@"; exit $?; fi

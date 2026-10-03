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

用法：xy（或 bash xray-manager.sh） [--yes] <命令> [参数]
无参数：打开交互菜单；help：显示本帮助。

  install [v版本]                 安装，默认 v26.3.27；重复安装保留节点
  upgrade v版本                  指定核心版本升级，保留上一版供回退
  rollback                       切换到上一版核心
  list                           列出节点（不显示秘密）
  add vless-reality ID 名称 端口 地址 SNI TARGET [UUID 私钥 公钥 ShortID]
  add vless-xhttp ID 名称 端口 地址 SNI TARGET PATH MODE [UUID 私钥 公钥 ShortID]
  add shadowsocks ID 名称 端口 地址 [密码]
  delete ID                      删除节点，需要确认或 --yes
  share ID                       显式输出含客户端秘密的分享链接
  service start|stop|restart|status|enable|disable
  schedule status|set HH:MM|disable 每日本机时区定时重启（停止的核心跳过）
  logs [行数]                    显示最近日志，默认 80 行
  diagnose                       检查版本、配置和服务健康
  backup /绝对路径/备份.json      保存私密 JSON（0600），拒绝覆盖已有文件
  restore /绝对路径/备份.json     校验并恢复节点，保留当前核心版本，需确认
  uninstall                      停服务，删除本项目程序和节点，需确认

菜单回车接受默认值，:q 取消；地址回车自动探测公网 IP。
端口与地址由节点配置指定；首次安装不开放任何公网监听。
CLI 返回：0 成功，1 操作失败，2 参数错误或取消；中断 130/143。
支持 REALITY、XHTTP 或 SS2022；重复安装会备份并清退已移除类型的旧节点。
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
    for file in xray-manager.sh install.sh lib/common.sh lib/state.sh lib/platform.sh lib/protocol.sh assets/xray-manager.service assets/xray-manager.openrc assets/xray-manager.logrotate assets/xray-manager-restart.service assets/xray-manager-restart.timer assets/xray-manager-restart.openrc assets/xray-manager-restart.py assets/xy; do
        [[ -f $XM_CODE_ROOT/$file ]] || { xm_error "程序文件缺失：$file"; return 1; }
        xm_atomic_copy "$XM_CODE_ROOT/$file" "$XM_HOME/$file" 0755 || return 1
    done
    if [[ -z $XM_ROOT ]]; then chown root:xray-manager "$XM_HOME/lib" "$XM_HOME/assets" || return 1; fi
}
xm_retire_trojan() {
    local bytes count backup
    [[ -f $XM_STATE && ! -L $XM_STATE ]] && xm_path_no_links "$XM_STATE" || return 1
    bytes=$(wc -c < "$XM_STATE") || return 1
    [[ $bytes =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] && ((bytes <= 16777216)) || { xm_error '状态文件超过 16 MiB，拒绝自动清退。'; return 1; }
    # Legacy type is recognized only for removal. No legacy certificate, key,
    # password, configuration or sharing semantics are supported by this code.
    jq -e 'type=="object" and ((keys|sort)==["core_version","nodes","schema_version"]) and .schema_version==1 and (.core_version|type=="string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and (.nodes|type=="array" and all(type=="object" and (.type as $type|["trojan","vless-reality","vless-xhttp","shadowsocks"]|index($type)!=null)))' "$XM_STATE" >/dev/null 2>&1 || { xm_error '状态结构或节点类型未知，拒绝自动清退。'; return 1; }
    count=$(jq '[.nodes[]|select(.type=="trojan")]|length' "$XM_STATE") || return 1
    if ((count == 0)); then state_validate "$XM_STATE"; return $?; fi
    xm_work_begin || return 1
    jq '.nodes|=map(select(.type!="trojan"))' "$XM_STATE" > "$XM_WORK_DIR/state-retired.json" || return 1
    state_validate "$XM_WORK_DIR/state-retired.json" || return 1
    backup=$(umask 077; mktemp "$XM_ETC/trojan-retired-backup.XXXXXXXX") || return 1
    if ! cat "$XM_STATE" > "$backup" || ! chmod 0600 "$backup"; then rm -f -- "$backup"; xm_error '原状态私密备份失败，未清退节点。'; return 1; fi
    xm_info "已保存完整原状态私密备份：$backup（0600，包含秘密，请妥善保管）。"
    state_apply "$XM_WORK_DIR/state-retired.json" || { xm_error '清退失败，旧配置与运行状态由事务保留/恢复；未更新已安装脚本。'; return 1; }
    xm_info "已清退 $count 个不再支持的旧节点；保留其余节点与核心版本。"
}

xm_install() {
    local version=${1:-$XM_DEFAULT_CORE_VERSION}
    (($# <= 1)) || { xm_usage_error 'install 最多接受一个版本参数。'; return 2; }
    xm_version_valid "$version" || return $?
    xm_require_root && platform_detect && platform_shortcut_preflight && platform_dependencies && platform_prepare && xm_lock || return 1
    if [[ -f $XM_STATE ]]; then
        xm_installed && xm_retire_trojan && xm_install_code && platform_install_service && platform_shortcut_install || return 1
        xm_info "已安装核心 $(jq -r .core_version "$XM_STATE")；保留节点。更换核心请使用 upgrade。入口：xy。"
        return 0
    fi
    xm_work_begin || return 1
    platform_fetch_core "$version" "$XM_WORK_DIR/xray" || return 1
    state_empty "$version" > "$XM_WORK_DIR/state.json" || return 1
    xm_install_code && state_apply "$XM_WORK_DIR/state.json" "$XM_WORK_DIR/xray" || return 1
    if ! platform_install_service || ! xm_service_call enable || ! xm_service_call start || ! platform_health || ! platform_shortcut_install; then
        xm_service_call stop >/dev/null 2>&1 || true
        xm_service_call disable >/dev/null 2>&1 || true
        platform_remove_service >/dev/null 2>&1 || true
        rm -f -- "$XM_STATE" "$XM_CONFIG" "$XM_BIN"
        xm_error '首次启动失败，已撤销服务和初始状态；可检查日志后重新 install。'; return 1
    fi
    xm_info "安装完成：核心 $version，无公网监听。入口：xy（或 bash $XM_HOME/xray-manager.sh）"
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
xm_node_unique_secrets() {
    local node=$1
    jq -e --argjson node "$node" '
      .nodes | all(. as $old | ["uuid","private_key","public_key","short_id","password","path"] |
        all(. as $key | ($node[$key] == null or $old[$key] == null or $node[$key] != $old[$key])))
    ' "$XM_STATE" >/dev/null || { xm_error '随机密钥、凭据或 XHTTP 路径与已有节点冲突，请重新添加或更换输入。'; return 1; }
}
xm_menu_draft() {
    local attempts
    for ((attempts=0; attempts<16; attempts++)); do
        XM_MENU_NODE=$(protocol_new "$@") || return 1
        xm_node_unique_secrets "$XM_MENU_NODE" && return 0
    done
    xm_error '无法生成不冲突的随机凭据，请重试。'; return 1
}
xm_add() {
    (($# >= 5)) || { xm_usage_error 'add 的参数不足。'; return 2; }
    xm_ready && xm_work_begin || return 1
    local node type=$1 id=$2 name=$3 port=$4
    case $type in
        vless-reality) (($# == 7 || $# == 11)) || { xm_usage_error 'VLESS 需要 SNI TARGET，可选的 UUID/私钥/公钥/ShortID 须同时提供。'; return 2; } ;;
        vless-xhttp) (($# == 9 || $# == 13)) || { xm_usage_error 'XHTTP 需要 SNI TARGET PATH MODE，可选四项密钥须同时提供。'; return 2; } ;;
        shadowsocks) (($# == 5 || $# == 6)) || { xm_usage_error 'Shadowsocks 密码可选。'; return 2; } ;;
        *) xm_usage_error '不支持此协议。'; return 2 ;;
    esac
    node=$(protocol_new "$@") || return 1
    xm_node_unique_secrets "$node" || return 1
    jq -e --arg id "$id" --arg name "$name" --argjson port "$port" '.nodes | all(.id != $id and .name != $name and .port != $port)' "$XM_STATE" >/dev/null || { xm_error '节点 ID、名称或端口已经存在。'; return 1; }
    platform_port_available "$port" || { xm_error '该端口已被监听，请换一个端口。'; return 1; }
    jq --argjson node "$node" '.nodes += [$node]' "$XM_STATE" > "$XM_WORK_DIR/state.json" || return 1
    state_apply "$XM_WORK_DIR/state.json" || return 1
    xm_info "节点 $id 已保存。运行 share $id 查看客户端链接。"
}
xm_delete() {
    (($# == 1)) || { xm_usage_error 'delete 需要节点 ID。'; return 2; }
    xm_ready && xm_work_begin || return 1
    jq -e --arg id "$1" '.nodes | any(.id == $id)' "$XM_STATE" >/dev/null || { xm_error '节点不存在。'; return 1; }
    xm_selected_unchanged "$1" || return 1
    xm_confirm "删除节点 $1？" || return 2
    xm_selected_unchanged "$1" || return 1
    jq --arg id "$1" '.nodes |= map(select(.id != $id))' "$XM_STATE" > "$XM_WORK_DIR/state.json" || return 1
    state_apply "$XM_WORK_DIR/state.json" || return 1
    xm_info "节点 $1 已删除。"
}
xm_share() {
    (($# == 1)) || { xm_usage_error 'share 需要节点 ID。'; return 2; }
    xm_ready || return 1
    local node
    node=$(jq -ec --arg id "$1" '.nodes[] | select(.id == $id)' "$XM_STATE") || { xm_error '节点不存在。'; return 1; }
    xm_selected_unchanged "$1" || return 1
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
    [[ $lines =~ ^[0-9]+$ && ${#lines} -le 4 ]] && ((10#$lines >= 1 && 10#$lines <= 1000)) || { xm_usage_error '行数必须在 1..1000。'; return 2; }
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
    local -a files=("$XM_STATE" "$XM_CONFIG" "$XM_ETC/core.previous-version" "$XM_BIN" "$XM_HOME/bin/xray.previous" "$XM_HOME/xray-manager.sh" "$XM_HOME/install.sh" "$XM_HOME/lib/common.sh" "$XM_HOME/lib/state.sh" "$XM_HOME/lib/platform.sh" "$XM_HOME/lib/protocol.sh" "$XM_HOME/assets/xray-manager.service" "$XM_HOME/assets/xray-manager.openrc" "$XM_HOME/assets/xray-manager.logrotate" "$XM_HOME/assets/xray-manager-restart.service" "$XM_HOME/assets/xray-manager-restart.timer" "$XM_HOME/assets/xray-manager-restart.openrc" "$XM_HOME/assets/xray-manager-restart.py" "$XM_HOME/assets/xy")
    for directory in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG"; do
        xm_owned "$directory" || { xm_error "目录缺少所有权标记，拒绝删除：$directory"; return 1; }
    done
    # Preflight every leaf and ancestor before stopping services or deleting anything.
    for file in "${files[@]}"; do xm_path_no_links "$file" || return 1; done
    platform_restart_schedule_preflight && platform_shortcut_preflight || return 1
    xm_service_call stop && xm_service_call disable && platform_remove_service && platform_shortcut_remove || return 1
    # Explicit names only: unknown files, backups, certificates, and service account remain.
    for file in "${files[@]}"; do
        xm_path_no_links "$file" || return 1
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
        schedule) xm_schedule "$@" ;;
        scheduled-restart) xm_scheduled_restart "$@" ;;
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
# A selection holds the exact node JSON from the displayed snapshot. Recheck
# under the command lock so an ID reused/edited while reading cannot be acted on.
xm_selected_unchanged() {
    [[ -n ${XM_SELECTED_NODE:-} ]] || return 0
    local actual
    actual=$(jq -ec --arg id "$1" '.nodes[]|select(.id==$id)' "$XM_STATE") || { xm_error '节点列表已变化，请重新选择编号。'; return 1; }
    [[ $actual == "$XM_SELECTED_NODE" ]] || { xm_error '节点信息已变化，请重新选择编号。'; return 1; }
}
xm_node_type_label() {
    case $1 in vless-reality) printf reality ;; vless-xhttp) printf xhttp ;; shadowsocks) printf ss2022 ;; *) printf unknown ;; esac
}
xm_node_summary() {
    local node=$1
    printf '%s名称%s %s  ·  %s类型%s %s\n' "$XM_UI_CYAN" "$XM_UI_RESET" "$(jq -r .name <<< "$node")" "$XM_UI_CYAN" "$XM_UI_RESET" "$(xm_node_type_label "$(jq -r .type <<< "$node")")" >&2
    printf '%s地址%s %s  ·  %s端口%s %s%s%s\n' "$XM_UI_CYAN" "$XM_UI_RESET" "$(jq -r .address <<< "$node")" "$XM_UI_CYAN" "$XM_UI_RESET" "$XM_UI_GREEN" "$(jq -r .port <<< "$node")" "$XM_UI_RESET" >&2
    printf 'ID %s\n' "$(jq -r .id <<< "$node")" >&2
}
xm_menu_node() {
    local action=$1 snapshot node index XM_CHOICE selected_id XM_SELECTED_NODE title
    local -a nodes=()
    xm_menu_ready || return 1
    snapshot=$(jq -ec '.nodes' "$XM_STATE") || return 1
    mapfile -t nodes < <(jq -c '.[]' <<< "$snapshot")
    case $action in view) title='查看节点' ;; share) title='分享链接' ;; delete) title='删除节点' ;; *) return 2 ;; esac
    xm_ui_heading "$title"
    if ((${#nodes[@]} == 0)); then xm_info '尚无节点，请先添加节点。'; return 0; fi
    for ((index=0; index<${#nodes[@]}; index++)); do
        node=${nodes[index]}
        printf '%s[%s]%s %s%s%s  ·  %s%s%s\n' "$XM_UI_BOLD" "$((index+1))" "$XM_UI_RESET" "$XM_UI_GREEN" "$(jq -r .name <<< "$node")" "$XM_UI_RESET" "$XM_UI_CYAN" "$(xm_node_type_label "$(jq -r .type <<< "$node")")" "$XM_UI_RESET" >&2
        printf '    %s:%s  ·  ID %s\n\n' "$(jq -r .address <<< "$node")" "$(jq -r .port <<< "$node")" "$(jq -r .id <<< "$node")" >&2
    done
    xm_ui_item 0 '返回'
    xm_info "输入 1..${#nodes[@]} 选择对应节点；0 返回，:q 取消。"
    while :; do
        xm_read XM_CHOICE '节点编号' '0' || return 2
        [[ $XM_CHOICE != 0 ]] || return 0
        if [[ $XM_CHOICE =~ ^[1-9][0-9]{0,5}$ ]] && ((XM_CHOICE <= ${#nodes[@]})); then break; fi
        xm_error "请输入 1..${#nodes[@]} 的编号或 0。"
    done
    XM_SELECTED_NODE=${nodes[XM_CHOICE-1]}
    selected_id=$(jq -r .id <<< "$XM_SELECTED_NODE") || return 1
    # view also validates under lock, then releases it before rendering.
    xm_ready || { xm_unlock; return 1; }
    xm_selected_unchanged "$selected_id" || { xm_unlock; return 1; }
    xm_unlock
    printf '\n' >&2; xm_node_summary "$XM_SELECTED_NODE"
    case $action in
        view)
            local field label value
            for field in sni target path mode method; do
                value=$(jq -r --arg field "$field" '.[$field] // empty' <<< "$XM_SELECTED_NODE")
                [[ -n $value ]] || continue
                case $field in sni) label='SNI' ;; target) label='REALITY 目标' ;; path) label='XHTTP 路径' ;; mode) label='XHTTP 模式' ;; method) label='加密算法' ;; esac
                printf '%s%s%s  %s%s%s\n' "$XM_UI_CYAN" "$label" "$XM_UI_RESET" "$XM_UI_GREEN" "$value" "$XM_UI_RESET" >&2
            done
            xm_info '凭据保持隐藏；查看客户端链接请选择“分享链接”。'
            ;;
        share) xm_info '以下链接包含客户端秘密，请妥善保管，勿公开。'; xm_dispatch share "$selected_id" ;;
        delete) xm_dispatch delete "$selected_id" ;;
    esac
}
xm_schedule() {
    local action=${1:-status}
    case $action in
        status|disable) (($# == 1)) || return 2 ;;
        set) (($# == 2)) && [[ $2 =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { xm_usage_error '定时时间必须为 HH:MM，例如 04:00，范围 00:00..23:59。'; return 2; } ;;
        *) xm_usage_error 'schedule 仅支持 status、set HH:MM 或 disable。'; return 2 ;;
    esac
    xm_ready || return 1
    if [[ $action == set ]]; then xm_confirm "每天本机时区 $2 重启正在运行的核心？停止的核心将跳过。" || return 2; fi
    if [[ $action == disable ]]; then xm_confirm '禁用每天定时重启？' || return 2; fi
    # The long-lived OpenRC scheduler must never inherit the manager lock.
    if [[ -n $XM_LOCK_FD ]]; then platform_restart_schedule "$@" {XM_LOCK_FD}>&-; else platform_restart_schedule "$@"; fi
}
xm_scheduled_restart() {
    (($# == 0)) || return 2
    xm_ready || return 1
    if ! xm_service_call status >/dev/null 2>&1; then xm_info '核心未运行，跳过定时重启。'; return 0; fi
    xm_service restart
}
xm_menu_schedule() {
    local row enabled time timezone next XM_CHOICE XM_TIME status_label
    xm_ui_heading '定时重启核心'
    row=$(xm_dispatch schedule status) || return 1
    IFS=$'\t' read -r enabled time timezone next <<< "$row"
    status_label=已禁用; [[ $enabled != enabled ]] || status_label=已启用
    printf '当前：%s%s%s  ·  每天 %s%s%s  ·  本机时区 %s%s%s\n' "$XM_UI_GREEN" "$status_label" "$XM_UI_RESET" "$XM_UI_GREEN" "$time" "$XM_UI_RESET" "$XM_UI_YELLOW" "$timezone" "$XM_UI_RESET" >&2
    [[ $next == - ]] || xm_info "下次执行：$next"
    xm_info '每天按本机时区执行；只重启正在运行的核心，已停止则跳过。不会补执行错过的任务。'
    xm_ui_item 1 '设置 / 修改每日时间'; xm_ui_item 2 '禁用定时重启'; xm_ui_item 0 '返回'
    while :; do
        xm_read XM_CHOICE '选择操作' '0' || return 2
        case $XM_CHOICE in
            0) return 0 ;;
            2) xm_dispatch schedule disable; return $? ;;
            1)
                while :; do
                    xm_read XM_TIME '每日重启时间（24小时 HH:MM，例如 04:00）' '04:00' || return 2
                    [[ $XM_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break
                    xm_error '请输入 00:00..23:59，小时和分钟均须两位。'
                done
                xm_dispatch schedule set "$XM_TIME"; return $? ;;
            *) xm_error '请输入 0、1 或 2。' ;;
        esac
    done
}

xm_menu_ready() {
    # Check installation before requesting secrets/network defaults. Release the
    # lock during human input; CLI mutation rechecks everything under its own lock.
    xm_ready || { xm_unlock; return 1; }
    xm_unlock
}
xm_menu_validate_field() {
    local field=$1 value=$2 candidate
    if [[ $field == port ]]; then
        [[ $value =~ ^[1-9][0-9]{0,4}$ ]] || { xm_error '端口必须为 1..65535 整数，不接受前导零。'; return 1; }
        candidate=$(jq -c --argjson port "$value" '.port=$port' <<< "$XM_MENU_NODE") || return 1
    else
        candidate=$(jq -c --arg field "$field" --arg value "$value" '.[$field]=$value' <<< "$XM_MENU_NODE") || return 1
    fi
    protocol_validate_node "$candidate" || return 1
    if [[ $field == id ]]; then
        jq -e --arg id "$value" '.nodes|all(.id!=$id)' "$XM_STATE" >/dev/null || { xm_error '该节点 ID 已存在，请重新输入。'; return 1; }
    elif [[ $field == name || $field == path ]]; then
        jq -e --arg field "$field" --arg value "$value" '.nodes|all(.[$field]!=$value)' "$XM_STATE" >/dev/null || { xm_error '该名称或路径已存在，请重新输入。'; return 1; }
    elif [[ $field == port ]]; then
        jq -e --argjson port "$value" '.nodes|all(.port!=$port)' "$XM_STATE" >/dev/null && platform_port_available "$value" || {
            xm_error '该端口已占用，请重新输入。'; return 1;
        }
    fi
    xm_node_unique_secrets "$candidate" || return 1
    XM_MENU_NODE=$candidate
}
xm_menu_field() {
    local variable=$1 field=$2 prompt=$3 default=${4:-} display=${5:-${4:-}} XM_INPUT
    while :; do
        xm_read XM_INPUT "$prompt" "$default" "$display" || return 2
        xm_menu_validate_field "$field" "$XM_INPUT" || continue
        printf -v "$variable" '%s' "$XM_INPUT"
        return 0
    done
}
xm_menu_address() {
    local variable=$1 XM_INPUT
    while :; do
        xm_read XM_INPUT '对外地址' '' '回车自动探测公网 IP；也可输入 IP/域名' || return 2
        if [[ -z $XM_INPUT ]]; then
            xm_info '正在探测公网地址…'
            XM_INPUT=$(platform_public_ip) || { xm_error '公网地址探测失败，请手动输入 IP/域名，或 :q 取消。'; continue; }
        fi
        xm_menu_validate_field address "$XM_INPUT" || continue
        printf -v "$variable" '%s' "$XM_INPUT"
        xm_info "对外地址：$XM_INPUT"
        return 0
    done
}
xm_menu_password() {
    local variable=$1 default=$2 XM_INPUT
    while :; do
        xm_read_secret XM_INPUT '节点密码/主密钥' "$default" || return 2
        xm_menu_validate_field password "$XM_INPUT" || continue
        printf -v "$variable" '%s' "$XM_INPUT"
        return 0
    done
}
xm_menu_add() {
    local XM_CHOICE XM_ID XM_NAME XM_PORT XM_ADDRESS XM_SNI XM_TARGET XM_PATH XM_MODE XM_PASSWORD
    local XM_MENU_NODE XM_INPUT suffix prefix default_id default_name default_port default_password type attempts
    xm_menu_ready || return 1
    xm_ui_heading '添加节点'
    xm_ui_item 1 'VLESS REALITY Vision'
    xm_ui_item 2 'VLESS XHTTP + REALITY'
    xm_ui_item 3 'Shadowsocks 2022'
    printf '\n' >&2; xm_ui_item 0 '返回'
    xm_info '回车使用方括号中的默认值；任意字段输入 :q 取消。'
    while :; do
        xm_read XM_CHOICE '选择协议' '1' || return 2
        case $XM_CHOICE in 0) return 0 ;; 1) type=vless-reality; prefix=REALITY; break ;; 2) type=vless-xhttp; prefix=XHTTP; break ;; 3) type=shadowsocks; prefix=SS2022; break ;; *) xm_error '请输入 0..3。' ;; esac
    done
    default_id=
    for ((attempts=0; attempts<16; attempts++)); do
        suffix=$(openssl rand -hex 4) || return 1
        default_id="node-$suffix"
        jq -e --arg id "$default_id" --arg name "${prefix}-${suffix}" '.nodes|all(.id!=$id and .name!=$name)' "$XM_STATE" >/dev/null && break
        default_id=
    done
    [[ -n $default_id ]] || { xm_error '随机 ID 生成失败，请重试。'; return 1; }
    default_name="${prefix}-${suffix}"
    default_port=$(platform_random_port "$XM_STATE") || { default_port=; xm_info '随机端口获取失败，请手动指定可用端口。'; }
    # A valid synthetic SS node reuses the authoritative protocol checks for
    # common fields. It does not create a listener or write any state.
    xm_menu_draft shadowsocks "$default_id" "$default_name" "${default_port:-1024}" localhost || return 1
    printf '\n' >&2
    xm_menu_field XM_ID id '节点 ID' "$default_id" || return 2
    xm_menu_field XM_NAME name '显示名称' "$default_name" || return 2
    xm_menu_field XM_PORT port '监听端口' "$default_port" "${default_port:-需手动输入；:q 取消}" || return 2
    xm_menu_address XM_ADDRESS || return 2
    case $type in
        vless-reality)
            xm_menu_draft "$type" "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" www.cloudflare.com www.cloudflare.com:443 || return 1
            xm_menu_field XM_SNI sni 'REALITY SNI' 'www.cloudflare.com' || return 2
            xm_menu_field XM_TARGET target 'REALITY 目标（域名:端口）' "${XM_SNI}:443" || return 2
            xm_info 'UUID、REALITY 密钥与 ShortID 已随机生成，秘密保持隐藏。'
            xm_dispatch add "$type" "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" "$XM_SNI" "$XM_TARGET" "$(jq -r .uuid <<< "$XM_MENU_NODE")" "$(jq -r .private_key <<< "$XM_MENU_NODE")" "$(jq -r .public_key <<< "$XM_MENU_NODE")" "$(jq -r .short_id <<< "$XM_MENU_NODE")"
            ;;
        vless-xhttp)
            for ((attempts=0; attempts<16; attempts++)); do
                XM_PATH="/$(openssl rand -hex 8)" || return 1
                jq -e --arg path "$XM_PATH" '.nodes|all(.path!=$path)' "$XM_STATE" >/dev/null && break
                XM_PATH=
            done
            [[ -n $XM_PATH ]] || { xm_error '随机路径生成失败，请重试。'; return 1; }
            xm_menu_draft "$type" "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" www.cloudflare.com www.cloudflare.com:443 "$XM_PATH" packet-up || return 1
            xm_menu_field XM_SNI sni 'REALITY SNI' 'www.cloudflare.com' || return 2
            xm_menu_field XM_TARGET target 'REALITY 目标（域名:端口）' "${XM_SNI}:443" || return 2
            xm_menu_field XM_PATH path 'XHTTP 路径（/开头，字母数字/_-）' "$XM_PATH" || return 2
            xm_menu_field XM_MODE mode 'XHTTP 模式（auto/packet-up/stream-up/stream-one）' packet-up || return 2
            xm_info 'UUID、REALITY 密钥与 ShortID 已随机生成，秘密保持隐藏。'
            xm_dispatch add "$type" "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" "$XM_SNI" "$XM_TARGET" "$XM_PATH" "$XM_MODE" "$(jq -r .uuid <<< "$XM_MENU_NODE")" "$(jq -r .private_key <<< "$XM_MENU_NODE")" "$(jq -r .public_key <<< "$XM_MENU_NODE")" "$(jq -r .short_id <<< "$XM_MENU_NODE")"
            ;;
        shadowsocks)
            default_password=$(jq -r .password <<< "$XM_MENU_NODE") || return 1
            xm_menu_password XM_PASSWORD "$default_password" || return 2
            xm_dispatch add "$type" "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" "$XM_PASSWORD"
            ;;
    esac
}
xm_menu_upgrade() {
    local releases channel tag published extra XM_CHOICE XM_VERSION XM_CONFIRM current selected_label index category_count display_date
    local -a tags=() labels=() dates=()
    xm_menu_ready || return 1
    current=$(jq -r .core_version "$XM_STATE") || return 1
    xm_ui_heading '升级 Xray 核心'
    xm_info "当前版本：$current"
    xm_info '正在获取官方正式版与预览版…'
    if releases=$(platform_release_choices); then
        for selected_label in stable preview; do
            category_count=0
            while IFS=$'\t' read -r channel tag published extra; do
                [[ $channel == "$selected_label" && $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $published =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ && -z $extra ]] || continue
                ((category_count < 2)) || continue
                tags+=("$tag"); labels+=("$channel"); dates+=("$published")
                category_count=$((category_count+1))
            done <<< "$releases"
        done
    else
        xm_error '版本列表获取失败，可手动输入版本或返回。'
    fi
    printf '\n' >&2
    for ((index=0; index<${#tags[@]}; index++)); do
        selected_label='正式版'; [[ ${labels[index]} != preview ]] || selected_label='预览版'
        xm_ui_item "$((index+1))" "${tags[index]}  ·  $selected_label"
        display_date=${dates[index]%Z}
        printf '        发布：%s UTC\n\n' "${display_date/T/ }" >&2
    done
    xm_ui_item m '手动输入版本'
    xm_ui_item 0 '返回'
    while :; do
        xm_read XM_CHOICE '选择版本' '0' || return 2
        case $XM_CHOICE in
            0) return 0 ;;
            m|M)
                while :; do
                    xm_read XM_VERSION '目标版本（例 v26.3.27）' '' ':q 返回' || return 2
                    xm_version_valid "$XM_VERSION" && break
                done
                selected_label='手动指定版本'; break ;;
            *)
                if [[ $XM_CHOICE =~ ^[1-9][0-9]{0,2}$ ]] && ((XM_CHOICE <= ${#tags[@]})); then
                    index=$((XM_CHOICE-1)); XM_VERSION=${tags[index]}; selected_label='正式版'; [[ ${labels[index]} != preview ]] || selected_label='预览版'; break
                fi
                xm_error '请输入列表编号、m 或 0。'
                ;;
        esac
    done
    printf '\n' >&2
    xm_info "将核心从 $current 升级到 $XM_VERSION（$selected_label）。"
    xm_info '确认后才下载和切换核心；失败会按原有事务回退。'
    xm_read XM_CONFIRM '确认升级？输入 y/yes（不区分大小写），其他输入取消' 'no' || return 2
    xm_yes "$XM_CONFIRM" || { xm_info '已取消升级。'; return 2; }
    xm_dispatch upgrade "$XM_VERSION"
}
xm_menu_service() {
    local XM_CHOICE action
    xm_menu_ready || return 1
    xm_ui_heading '服务操作'
    xm_ui_item 1 '启动'; xm_ui_item 2 '停止'; xm_ui_item 3 '重启'
    printf '\n' >&2
    xm_ui_item 4 '状态'; xm_ui_item 5 '开机启动'; xm_ui_item 6 '取消开机启动'
    printf '\n' >&2; xm_ui_item 7 '定时重启核心'; xm_ui_item 0 '返回'
    while :; do
        xm_read XM_CHOICE '选择操作' '0' || return 2
        case $XM_CHOICE in 0) return 0 ;; 1) action=start; break ;; 2) action=stop; break ;; 3) action=restart; break ;; 4) action=status; break ;; 5) action=enable; break ;; 6) action=disable; break ;; 7) xm_menu_schedule; return $? ;; *) xm_error '请输入 0..7。' ;; esac
    done
    xm_dispatch service "$action"
}
xm_menu_render() {
    local version='未安装' count=0 status='未运行' width status_color=$XM_UI_YELLOW
    width=$(xm_terminal_width)
    if [[ -f $XM_STATE ]] && command -v jq >/dev/null 2>&1; then
        # Never render untrusted state text as ANSI: version has a strict alphabet.
        version=$(jq -r '.core_version | select(type=="string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$XM_STATE" 2>/dev/null)
        [[ -n $version ]] || version='状态异常'
        count=$(jq '.nodes|length' "$XM_STATE" 2>/dev/null); [[ $count =~ ^[0-9]+$ ]] || count='?'
        if platform_detect >/dev/null 2>&1 && xm_service_call status >/dev/null 2>&1; then status='运行中'; status_color=$XM_UI_GREEN; fi
    fi
    printf '\n' >&2
    if [[ $width =~ ^[0-9]+$ && $width -lt 60 ]]; then printf '%sXray 管理%s\n' "$XM_UI_BOLD" "$XM_UI_RESET" >&2; else printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  Xray 管理  ·  xray-manager\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$XM_UI_BOLD" "$XM_UI_RESET" >&2; fi
    printf '\n  核心 %s\n  节点 %s  ·  %s%s%s\n' "$version" "$count" "$status_color" "$status" "$XM_UI_RESET" >&2
    if [[ $width =~ ^[0-9]+$ && $width -ge 60 ]]; then
        printf '\n' >&2
        printf '%s核心管理%s\n' "$XM_UI_CYAN" "$XM_UI_RESET" >&2
        xm_ui_pair 1 '安装核心' 2 '选择版本并升级'; xm_ui_item 3 '核心回退'
        printf '\n%s节点管理%s\n' "$XM_UI_CYAN" "$XM_UI_RESET" >&2
        xm_ui_pair 4 '查看节点' 5 '添加节点'; xm_ui_pair 6 '删除节点' 7 '分享链接'
        printf '\n%s运行维护%s\n' "$XM_UI_CYAN" "$XM_UI_RESET" >&2
        xm_ui_pair 8 '服务操作' 9 '查看日志'; xm_ui_item 10 '运行诊断'
        printf '\n%s数据管理%s\n' "$XM_UI_CYAN" "$XM_UI_RESET" >&2
        xm_ui_pair 11 '备份状态' 12 '恢复状态'; xm_ui_item 13 '卸载管理器'
    else
        xm_ui_heading '核心管理'
        xm_ui_item 1 '安装核心'; xm_ui_item 2 '选择版本并升级'; xm_ui_item 3 '核心回退'
        xm_ui_heading '节点管理'
        xm_ui_item 4 '查看节点'; xm_ui_item 5 '添加节点'; xm_ui_item 6 '删除节点'; xm_ui_item 7 '分享链接'
        xm_ui_heading '运行维护'
        xm_ui_item 8 '服务操作'; xm_ui_item 9 '查看日志'; xm_ui_item 10 '运行诊断'
        xm_ui_heading '数据管理'
        xm_ui_item 11 '备份状态'; xm_ui_item 12 '恢复状态'; xm_ui_item 13 '卸载管理器'
    fi
    printf '\n' >&2; xm_ui_item 0 '退出'
    printf '\n' >&2
}
xm_menu() {
    local XM_CHOICE XM_FILE
    xm_require_root || return 1
    xm_ui_init
    while :; do
        xm_menu_render
        xm_read XM_CHOICE '选择菜单编号' '0' || { xm_info '输入结束或已取消，已退出。'; return 0; }
        case $XM_CHOICE in
            0) return 0 ;;
            1) xm_dispatch install ;;
            2) xm_menu_upgrade ;;
            3) xm_dispatch rollback ;;
            4) xm_menu_node view ;;
            5) xm_menu_add ;;
            6) xm_menu_node delete ;;
            7) xm_menu_node share ;;
            8) xm_menu_service ;;
            9) xm_dispatch logs ;;
            10) xm_dispatch diagnose ;;
            11) xm_menu_ready && xm_read XM_FILE '备份绝对路径' && xm_dispatch backup "$XM_FILE" ;;
            12) xm_menu_ready && xm_read XM_FILE '备份绝对路径' && xm_dispatch restore "$XM_FILE" ;;
            13) xm_dispatch uninstall ;;
            *) xm_error '选择无效，请输入菜单编号。' ;;
        esac
        # Keep prior output visible; EOF exits on the next prompt without looping.
    done
}
xm_main() {
    umask 077
    if [[ ${1:-} == --yes ]]; then XM_YES=1; shift; fi
    if [[ ${1:-} == -- ]]; then shift; fi
    xm_dispatch "$@"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then xm_main "$@"; exit $?; fi

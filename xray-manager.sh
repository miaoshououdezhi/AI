#!/usr/bin/env bash
# xray-manager: the public CLI and compact Chinese terminal interface.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    if [[ -t 2 && -z ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]]; then
        printf '\033[91m[错误] 需要 Bash 4.4 或更新版本，请运行 sh install.sh。\033[0m\n' >&2
    else
        printf '[错误] 需要 Bash 4.4 或更新版本，请运行 sh install.sh。\n' >&2
    fi
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
  edit ID FIELD VALUE             修改匹配协议字段；keys PRIVATE PUBLIC
  edit ID tls CERT KEY [SNI]       同时替换 TLS 证书和私钥（私密 PEM 内嵌）
  add vless-ws ID 名称 端口 地址 SNI PATH 证书路径 私钥路径 [UUID]
  add socks5 ID 名称 端口 地址 [用户名 密码]
  add anytls|hysteria2 ID 名称 端口 地址 SNI 证书路径 私钥路径 [密码]
  add tuicv5 ID 名称 端口 地址 SNI 证书路径 私钥路径 [UUID 密码]
  delete ID                      删除节点，需要确认或 --yes
  share ID                       显式输出含客户端秘密的分享链接
  service start|stop|restart|status|enable|disable
  schedule status|set HH:MM|disable 每日本机时区定时重启（停止的核心跳过）
  logs [行数]                    显示最近日志，默认 80 行
  diagnose                       检查版本、配置和服务健康
  export /绝对路径/配置.json      导出全部节点/TLS PEM（0600），拒绝覆盖
  backup                         export 的兼容别名
  import /绝对路径/配置.json      校验导入全部节点，保留核心版本，需要确认
  restore                        import 的兼容别名
  uninstall                      完全清除本项目及已记录且不共享的新增依赖

菜单回车接受默认值，:q 取消；地址回车自动探测公网 IP。
端口与地址由节点配置指定；首次安装不开放任何公网监听。
CLI 返回：0 成功，1 操作失败，2 参数错误或取消；中断 130/143。
支持 REALITY、XHTTP、SS2022、VLESS(ws)、SOCKS5；AnyTLS/HY2/TUICv5使用辅助核心；重复安装会备份并清退已移除类型的旧节点。
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
    xm_require_root && xm_need_commands jq flock && platform_detect && xm_installed && xm_lock && state_validate "$XM_STATE" maintenance || return 1
    if [[ -e $XM_EXTRA_BIN ]]; then platform_extra_ensure || return 1; fi
}
xm_install_code() {
    local file
    [[ $XM_CODE_ROOT == "$XM_HOME" ]] && return 0
    for file in lib assets; do
        [[ ! -L $XM_HOME/$file ]] || return 1
        mkdir -p -- "$XM_HOME/$file" || return 1
        chmod 0750 "$XM_HOME/$file" || return 1
    done
    for file in xray-manager.sh install.sh lib/common.sh lib/state.sh lib/platform.sh lib/protocol.sh assets/xray-manager.service assets/xray-manager.openrc assets/xray-manager.logrotate assets/xray-manager-restart.service assets/xray-manager-restart.timer assets/xray-manager-restart.openrc assets/xray-manager-restart.py assets/xy assets/xray-manager-extra.service assets/xray-manager-extra.openrc; do
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
    jq -e 'type=="object" and ((keys|sort)==["core_version","nodes","schema_version"]) and .schema_version==1 and (.core_version|type=="string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and (.nodes|type=="array" and all(type=="object" and (.type as $type|["trojan","vless-reality","vless-xhttp","shadowsocks","vless-ws","socks5","anytls","hysteria2","tuicv5"]|index($type)!=null)))' "$XM_STATE" >/dev/null 2>&1 || { xm_error '状态结构或节点类型未知，拒绝自动清退。'; return 1; }
    count=$(jq '[.nodes[]|select(.type=="trojan")]|length' "$XM_STATE") || return 1
    if ((count == 0)); then state_validate "$XM_STATE" maintenance; return $?; fi
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
    local version=${1:-$XM_DEFAULT_CORE_VERSION} refresh_extra=0
    (($# <= 1)) || { xm_usage_error 'install 最多接受一个版本参数。'; return 2; }
    xm_version_valid "$version" || return $?
    xm_require_root && platform_detect && platform_shortcut_preflight && platform_dependencies_snapshot && platform_dependencies && platform_prepare && xm_lock || return 1
    if [[ -f $XM_STATE ]]; then
        xm_installed || return 1
        if [[ -e $XM_EXTRA_BIN || -L $XM_EXTRA_BIN ]]; then
            platform_extra_ensure && platform_extra_preflight || return 1
            refresh_extra=1
        fi
        xm_retire_trojan && xm_install_code && platform_install_service || return 1
        # Re-register owned service definitions without start/enable actions.
        if [[ $refresh_extra == 1 ]]; then platform_extra_install_service || return 1; fi
        platform_shortcut_install || return 1
        xm_success "已安装核心 $(jq -r .core_version "$XM_STATE")；保留节点。更换核心请使用 upgrade。入口：xy。"
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
        rm -f -- "$XM_STATE" "$XM_CONFIG" "$XM_EXTRA_CONFIG" "$XM_BIN"
        xm_error '首次启动失败，已撤销服务和初始状态；可检查日志后重新 install。'; return 1
    fi
    xm_success "安装完成：核心 $version，无公网监听。入口：xy（或 bash $XM_HOME/xray-manager.sh）"
}
xm_upgrade() {
    (($# == 1)) || { xm_usage_error 'upgrade 需要显式指定 v版本。'; return 2; }
    xm_version_valid "$1" || return $?
    xm_ready && xm_work_begin || return 1
    if [[ $(jq -r '.core_version' "$XM_STATE") == "$1" ]]; then xm_info '已经是该核心版本。'; return 0; fi
    platform_fetch_core "$1" "$XM_WORK_DIR/xray" || return 1
    jq --arg version "$1" '.core_version=$version' "$XM_STATE" > "$XM_WORK_DIR/state.json" || return 1
    state_apply "$XM_WORK_DIR/state.json" "$XM_WORK_DIR/xray" || return 1
    xm_success "核心已切换至 $1，原运行状态已保留。"
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
    xm_success "核心已回退至 $version。"
}
xm_list() {
    (($# == 0)) || { xm_usage_error 'list 不接受参数。'; return 2; }
    xm_ready || return 1
    jq -r 'if (.nodes|length)==0 then "尚无节点。选择添加节点开始配置。" else "ID\t名称\t协议\t端口\t地址", (.nodes[] | [.id,.name,.type,(.port|tostring),.address] | @tsv) end' "$XM_STATE"
}
xm_node_unique_secrets() {
    local node=$1 exclude=${2:-}
    jq -Rse --arg exclude "$exclude" --slurpfile state "$XM_STATE" '
      fromjson as $node | $state[0].nodes | map(select(.id!=$exclude)) | all(. as $old | ["uuid","private_key","public_key","short_id","password","username","path"] |
        all(. as $key | ($node[$key] == null or $old[$key] == null or $node[$key] != $old[$key])))
    ' <<< "$node" >/dev/null || { xm_error '随机密钥、凭据或 XHTTP 路径与已有节点冲突，请重新添加或更换输入。'; return 1; }
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
        vless-ws) (($# == 9 || $# == 10)) || { xm_usage_error 'WS需要SNI PATH CERT KEY，可选UUID。'; return 2; } ;;
        socks5) (($# == 5 || $# == 7)) || { xm_usage_error 'SOCKS5可选用户名和密码须成对。'; return 2; } ;;
        anytls|hysteria2) (($# == 8 || $# == 9)) || { xm_usage_error 'TLS协议需要SNI CERT KEY，可选密码。'; return 2; } ;;
        tuicv5) (($# == 8 || $# == 10)) || { xm_usage_error 'TUIC需要SNI CERT KEY，可选UUID和密码须成对。'; return 2; } ;;
        shadowsocks) (($# == 5 || $# == 6)) || { xm_usage_error 'Shadowsocks 密码可选。'; return 2; } ;;
        *) xm_usage_error '不支持此协议。'; return 2 ;;
    esac
    node=$(protocol_new "$@") || return 1
    xm_node_unique_secrets "$node" || return 1
    jq -e --arg id "$id" --arg name "$name" --argjson port "$port" '.nodes | all(.id != $id and .name != $name and .port != $port)' "$XM_STATE" >/dev/null || { xm_error '节点 ID、名称或端口已经存在。'; return 1; }
    platform_port_available "$port" || { xm_error '该端口已被监听，请换一个端口。'; return 1; }
    jq --slurpfile state "$XM_STATE" '. as $node | $state[0] | .nodes += [$node]' <<< "$node" > "$XM_WORK_DIR/state.json" || return 1
    state_apply "$XM_WORK_DIR/state.json" || return 1
    xm_success "节点 $id 已保存。运行 share $id 查看客户端链接。"
}
xm_node_patch() {
    local node=$1 field=$2 value=$3 type candidate
    type=$(jq -r .type <<< "$node") || return 1
    [[ $field != shortid ]] || field=short_id
    case "$type:$field" in
        *:name|*:port|*:address|shadowsocks:password|vless-reality:uuid|vless-reality:sni|vless-reality:target|vless-reality:short_id|vless-reality:keys|vless-xhttp:uuid|vless-xhttp:sni|vless-xhttp:target|vless-xhttp:short_id|vless-xhttp:keys|vless-xhttp:path|vless-xhttp:mode|vless-ws:uuid|vless-ws:sni|vless-ws:path|vless-ws:tls|anytls:sni|anytls:password|anytls:tls|hysteria2:sni|hysteria2:password|hysteria2:tls|tuicv5:sni|tuicv5:uuid|tuicv5:password|tuicv5:tls|socks5:username|socks5:password) ;;
        *) xm_error '该字段不属于当前节点协议；ID、类型和加密算法固定。'; return 2 ;;
    esac
    if [[ $field == tls ]]; then
        (($# == 4 || $# == 5)) || { xm_error 'TLS需要证书和私钥路径，可选新SNI。'; return 2; }
        local tls sni=${5:-$(jq -r .sni <<< "$node")}
        tls=$(protocol_tls_read "$value" "$4" "$sni") || return 1
        candidate=$(printf '%s\0' "$node" "$tls" "$sni" | jq -Rsc 'split("\u0000") as $data | ($data[0]|fromjson) + ($data[1]|fromjson) | .sni=$data[2]') || return 1
    elif [[ $field == keys ]]; then
        (($# == 4)) || { xm_error 'REALITY 密钥须同时提供私钥和公钥。'; return 2; }
        candidate=$(printf '%s\0' "$node" "$value" "$4" | jq -Rsc 'split("\u0000") as $data | ($data[0]|fromjson) | .private_key=$data[1] | .public_key=$data[2]') || return 1
    elif [[ $field == port ]]; then
        (($# == 3)) && [[ $value =~ ^[1-9][0-9]{0,4}$ ]] || { xm_error '端口须为 1..65535，不接受前导零。'; return 2; }
        candidate=$(jq -c --argjson port "$value" '.port=$port' <<< "$node") || return 1
    else
        (($# == 3)) || return 2
        candidate=$(printf '%s\0' "$node" "$value" | jq -Rsc --arg field "$field" 'split("\u0000") as $data | ($data[0]|fromjson) | .[$field]=$data[1]') || return 1
    fi
    protocol_validate_node "$candidate" || return 1
    printf '%s\n' "$candidate"
}
xm_edit_conflicts() {
    local original=$1 candidate=$2 id port previous_port name
    id=$(jq -r .id <<< "$original"); port=$(jq -r .port <<< "$candidate")
    previous_port=$(jq -r .port <<< "$original"); name=$(jq -r .name <<< "$candidate")
    jq -e --arg id "$id" --arg name "$name" --argjson port "$port" '.nodes|all(.id==$id or (.name!=$name and .port!=$port))' "$XM_STATE" >/dev/null || { xm_error '名称或端口与其他节点冲突，请重新输入。'; return 1; }
    xm_node_unique_secrets "$candidate" "$id" || return 1
    [[ $port == "$previous_port" ]] || platform_port_available "$port" || { xm_error '新端口已被监听，请重新输入。'; return 1; }
}
xm_edit() {
    (($# >= 3 && $# <= 5)) || { xm_usage_error 'edit ID FIELD VALUE；keys需PRIVATE PUBLIC，tls需CERT KEY [SNI]。'; return 2; }
    local id=$1 original candidate actual
    shift
    xm_ready || return 1
    original=$(jq -ec --arg id "$id" '.nodes[]|select(.id==$id)' "$XM_STATE") || { xm_error '节点不存在。'; return 1; }
    xm_selected_unchanged "$id" || return 1
    candidate=$(xm_node_patch "$original" "$@") || return $?
    [[ -z ${XM_EXPECTED_CANDIDATE:-} || $candidate == "$XM_EXPECTED_CANDIDATE" ]] || { xm_error '输入的证书文件已变化，请重新编辑。'; return 1; }
    xm_edit_conflicts "$original" "$candidate" || return 1
    xm_unlock
    [[ $candidate != "$original" ]] || { xm_info '节点未变化，无须保存。'; return 0; }
    xm_node_summary "$candidate"
    xm_confirm "保存节点 $id 的修改？" || return 2
    # Human input holds no lock. Verify the exact source again when committing.
    xm_ready || return 1
    actual=$(jq -ec --arg id "$id" '.nodes[]|select(.id==$id)' "$XM_STATE") || return 1
    [[ $actual == "$original" ]] || { xm_error '节点信息已变化，请重新选择并编辑。'; return 1; }
    xm_selected_unchanged "$id" && protocol_validate_node "$candidate" && xm_edit_conflicts "$original" "$candidate" && xm_work_begin || return 1
    jq --arg id "$id" --slurpfile state "$XM_STATE" '. as $node | $state[0] | .nodes|=map(if .id==$id then $node else . end)' <<< "$candidate" > "$XM_WORK_DIR/state.json" || return 1
    state_apply "$XM_WORK_DIR/state.json" "" maintenance || return 1
    xm_success "节点 $id 已更新，ID 与类型保持不变。"
}
xm_edit_secret() {
    local variable=$1 prompt=$2 default=$3 reply
    [[ $variable =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 1
    while :; do
        printf '%s [回车保持现有值；隐藏]：' "$prompt" >&2
        IFS= read -r -s reply || { printf '\n' >&2; return 2; }
        printf '\n' >&2
        [[ $reply != :q ]] || return 2
        xm_input_safe "$reply" || { xm_error '输入不能含控制字符。'; continue; }
        [[ -n $reply ]] || reply=$default
        printf -v "$variable" '%s' "$reply"
        return 0
    done
}
xm_menu_edit() {
    local original=$1 field=${2:-} type id XM_CHOICE XM_VALUE XM_PRIVATE XM_PUBLIC XM_CERT XM_KEY XM_SNI XM_CONFIRM candidate index
    local -a fields=(port address) captions=('监听端口' '对外地址（IP/域名）')
    type=$(jq -r .type <<< "$original"); id=$(jq -r .id <<< "$original")
    if [[ -z $field ]]; then
        case $type in
            vless-reality|vless-xhttp)
                fields+=(sni target uuid short_id keys)
                captions+=('REALITY SNI' 'REALITY 目标（域名:端口）' 'UUID' 'ShortID（偶数位十六进制）' 'REALITY 公私钥（成对替换）')
                [[ $type != vless-xhttp ]] || { fields+=(path mode); captions+=('XHTTP 路径（/开头，字母数字/_-）' 'XHTTP 模式（auto/packet-up/stream-up/stream-one）'); } ;;
            shadowsocks) fields+=(password); captions+=('SS2022 主密钥（16字节标准Base64）') ;;
            socks5) fields+=(username password); captions+=('认证用户名（3..64字母数字_-）' '认证密码（16..128字符）') ;;
            vless-ws|anytls|hysteria2|tuicv5)
                fields+=(sni tls); captions+=('TLS SNI（须匹配证书SAN）' 'TLS证书/私钥（成对替换，可同时修改SNI）')
                if [[ $type == vless-ws ]]; then fields+=(uuid path); captions+=('UUID' 'WS路径（/开头，字母数字/_-）')
                else fields+=(password); captions+=('认证密码（16..256字符）'); fi
                if [[ $type == tuicv5 ]]; then fields+=(uuid); captions+=('UUID'); fi ;;

            *) return 1 ;;
        esac
        xm_ui_heading '修改节点配置'
        for ((index=0; index<${#fields[@]}; index++)); do xm_ui_item "$((index+1))" "${captions[index]}"; done
        xm_ui_item 0 '返回'
        while :; do
            xm_read XM_CHOICE '配置编号' '0' || return 2
            [[ $XM_CHOICE != 0 ]] || return 0
            if [[ $XM_CHOICE =~ ^[1-9][0-9]{0,2}$ ]] && ((XM_CHOICE <= ${#fields[@]})); then index=$((XM_CHOICE-1)); field=${fields[index]}; break; fi
            xm_error '请输入列表中的配置编号或 0。'
        done
    else
        index=0; captions=('显示名称')
    fi
    xm_info '回车保留当前值；:q 取消。ID 与协议类型固定，秘密不默认回显。'
    while :; do
        case $field in
            tls)
                xm_read XM_SNI '新TLS SNI' "$(jq -r .sni <<< "$original")" || return 2
                xm_read XM_CERT '新证书绝对路径' '/etc/ssl/xray/fullchain.pem' || return 2
                xm_read XM_KEY '匹配私钥绝对路径' '/etc/ssl/xray/private.key' || return 2
                candidate=$(xm_node_patch "$original" tls "$XM_CERT" "$XM_KEY" "$XM_SNI") || continue ;;
            keys)
                xm_edit_secret XM_PRIVATE 'REALITY 私钥（回车保持现有值）' "$(jq -r .private_key <<< "$original")" || return 2
                xm_edit_secret XM_PUBLIC 'REALITY 公钥（回车保持现有值）' "$(jq -r .public_key <<< "$original")" || return 2
                candidate=$(xm_node_patch "$original" keys "$XM_PRIVATE" "$XM_PUBLIC") || continue ;;
            uuid|short_id|password)
                xm_edit_secret XM_VALUE "${captions[index]}（回车保持现有值）" "$(jq -r --arg field "$field" '.[$field]' <<< "$original")" || return 2
                candidate=$(xm_node_patch "$original" "$field" "$XM_VALUE") || continue ;;
            *)
                xm_read XM_VALUE "${captions[index]}" "$(jq -r --arg field "$field" '.[$field]' <<< "$original")" || return 2
                candidate=$(xm_node_patch "$original" "$field" "$XM_VALUE") || continue ;;
        esac
        xm_edit_conflicts "$original" "$candidate" || continue
        break
    done
    [[ $candidate != "$original" ]] || { xm_info '节点未变化，无须保存。'; return 0; }
    xm_node_summary "$candidate"
    xm_read XM_CONFIRM '保存修改？输入 y/yes（不区分大小写）' 'no' || return 2
    xm_yes "$XM_CONFIRM" || { xm_info '已取消修改。'; return 2; }
    local XM_YES=1 XM_EXPECTED_CANDIDATE=$candidate
    if [[ $field == tls ]]; then xm_dispatch edit "$id" tls "$XM_CERT" "$XM_KEY" "$XM_SNI"
    elif [[ $field == keys ]]; then xm_dispatch edit "$id" keys "$XM_PRIVATE" "$XM_PUBLIC"; else xm_dispatch edit "$id" "$field" "$XM_VALUE"; fi
}
xm_menu_node_details() {
    local node=$1 XM_CHOICE field label value
    for field in sni target path mode method; do
        value=$(jq -r --arg field "$field" '.[$field] // empty' <<< "$node")
        [[ -n $value ]] || continue
        case $field in sni) label='SNI' ;; target) label='REALITY 目标' ;; path) label='XHTTP 路径' ;; mode) label='XHTTP 模式' ;; method) label='加密算法' ;; esac
        printf '%s%s%s  %s%s%s\n' "$XM_UI_CYAN" "$label" "$XM_UI_RESET" "$XM_UI_GREEN" "$value" "$XM_UI_RESET" >&2
    done
    xm_info '凭据保持隐藏；查看客户端链接请选择“分享链接”。'
    printf '\n' >&2
    xm_ui_item 1 '修改名称'; xm_ui_item 2 '修改节点配置'; xm_ui_item 0 '返回'
    while :; do
        xm_read XM_CHOICE '节点操作编号' '0' || return 2
        case $XM_CHOICE in 0) return 0 ;; 1) xm_menu_edit "$node" name; return $? ;; 2) xm_menu_edit "$node"; return $? ;; *) xm_error '请输入 0、1 或 2。' ;; esac
    done
}

xm_delete() {
    (($# == 1)) || { xm_usage_error 'delete 需要节点 ID。'; return 2; }
    xm_ready && xm_work_begin || return 1
    jq -e --arg id "$1" '.nodes | any(.id == $id)' "$XM_STATE" >/dev/null || { xm_error '节点不存在。'; return 1; }
    xm_selected_unchanged "$1" || return 1
    xm_confirm "删除节点 $1？" || return 2
    xm_selected_unchanged "$1" || return 1
    jq --arg id "$1" '.nodes |= map(select(.id != $id))' "$XM_STATE" > "$XM_WORK_DIR/state.json" || return 1
    state_apply "$XM_WORK_DIR/state.json" "" maintenance || return 1
    xm_success "节点 $1 已删除。"
}
xm_share() {
    (($# == 1)) || { xm_usage_error 'share 需要节点 ID。'; return 2; }
    xm_ready || return 1
    local node
    node=$(jq -ec --arg id "$1" '.nodes[] | select(.id == $id)' "$XM_STATE") || { xm_error '节点不存在。'; return 1; }
    xm_selected_unchanged "$1" || return 1
    protocol_share "$node"
}
xm_services_restore_running() {
    local main_running=$1 extra_running=$2 failed=0
    xm_service_call stop >/dev/null 2>&1 || failed=1
    if [[ -x $XM_EXTRA_BIN ]]; then xm_extra_service_call stop >/dev/null 2>&1 || failed=1; fi
    if [[ $main_running == 1 ]]; then xm_service_call start >/dev/null 2>&1 && platform_health >/dev/null 2>&1 || failed=1; fi
    if [[ $extra_running == 1 ]]; then xm_extra_service_call start >/dev/null 2>&1 && platform_extra_health >/dev/null 2>&1 || failed=1; fi
    return "$failed"
}
xm_service_validate() {
    xm_work_begin && xm_private_temp || return 1
    protocol_generate "$XM_STATE" "$XM_TEMP_DIR/check.json" && state_native_validate "$XM_BIN" "$XM_TEMP_DIR/check.json" || return 1
    cmp -s "$XM_TEMP_DIR/check.json" "$XM_CONFIG" || { xm_error 'Xray 配置与状态不一致，请导入配置恢复。'; return 1; }
    if protocol_has_extra "$XM_STATE"; then
        platform_extra_ensure && protocol_generate_extra "$XM_STATE" "$XM_TEMP_DIR/check-extra.json" && state_extra_native_validate "$XM_TEMP_DIR/check-extra.json" || return 1
        cmp -s "$XM_TEMP_DIR/check-extra.json" "$XM_EXTRA_CONFIG" || { xm_error '辅助核心配置与状态不一致，请导入配置恢复。'; return 1; }
    fi
    xm_temp_cleanup
}
xm_service() {
    (($# == 1)) || { xm_usage_error 'service 需要一个操作。'; return 2; }
    case $1 in start|stop|restart|status|enable|disable) ;; *) xm_usage_error '未知服务操作。'; return 2 ;; esac
    xm_ready || return 1
    local main_running=0 extra_running=0 failed=0 action=$1
    xm_service_call status >/dev/null 2>&1 && main_running=1
    if [[ -x $XM_EXTRA_BIN ]]; then xm_extra_service_call status >/dev/null 2>&1 && extra_running=1; fi
    if [[ $action == status ]]; then
        xm_info "Xray：$([[ $main_running == 1 ]] && printf 运行中 || printf 已停止)"
        xm_info "辅助核心：$([[ $extra_running == 1 ]] && printf 运行中 || printf 已停止或未安装)"
        return 0
    fi
    if [[ $action == start || $action == restart ]]; then xm_service_validate || return 1; fi
    xm_service_call "$action" || failed=1
    if [[ $failed == 0 && ( $action == start || $action == restart ) ]]; then platform_health || failed=1; fi
    if [[ $failed == 0 && -x $XM_EXTRA_BIN ]]; then
        if [[ $action == stop || $action == disable ]] || protocol_has_extra "$XM_STATE"; then
            xm_extra_service_call "$action" || failed=1
            if [[ $failed == 0 && ( $action == start || $action == restart ) ]]; then platform_extra_health || failed=1; fi
        fi
    fi
    if [[ $failed == 1 ]]; then
        if [[ $action == start || $action == restart || $action == stop ]]; then xm_services_restore_running "$main_running" "$extra_running" || xm_error '服务运行状态恢复失败，请诊断。'; fi
        xm_error '服务操作失败。'; return 1
    fi
    xm_success "服务操作完成：$action（Xray 和已配置的辅助核心）。"
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
    xm_ok '状态与原生配置校验通过。'
    platform_health || { xm_error '服务未运行或不健康。'; return 1; }
    if protocol_has_extra "$XM_STATE"; then
        protocol_generate_extra "$XM_STATE" "$XM_TEMP_DIR/check-extra.json" && state_extra_native_validate "$XM_TEMP_DIR/check-extra.json" && cmp -s "$XM_TEMP_DIR/check-extra.json" "$XM_EXTRA_CONFIG" && platform_extra_health || { xm_error '辅助核心配置或健康检查失败。'; return 1; }
    fi
    xm_ok '服务健康检查通过。'
}
xm_backup() {
    (($# == 1)) || { xm_usage_error 'export 需要绝对文件路径。'; return 2; }
    [[ $1 == /* && $1 != */ ]] || { xm_usage_error '导出路径必须是绝对文件路径。'; return 2; }
    xm_ready && xm_path_no_links "$1" || return 1
    (umask 077; set -o noclobber; cat "$XM_STATE" > "$1") || { xm_error '导出写入失败：目录须存在，目标文件须不存在。'; return 1; }
    xm_success "配置已导出：$1；节点 $(jq '.nodes|length' "$XM_STATE")；权限 0600。"
    xm_warning '文件包含密码、私钥和证书，迁移完成后请妥善保管。'
}
xm_restore() {
    (($# == 1)) || { xm_usage_error 'import 需要现有配置的绝对路径。'; return 2; }
    [[ $1 == /* && $1 != */ ]] && xm_path_no_links "$1" || { xm_usage_error '导入须选择安全的绝对文件路径。'; return 2; }
    xm_ready && xm_work_begin && state_validate "$1" || return 1
    local before node port already_owned count
    before=$(jq -c . "$XM_STATE") || return 1
    cp -- "$1" "$XM_WORK_DIR/import.json" && chmod 0600 "$XM_WORK_DIR/import.json" && state_validate "$XM_WORK_DIR/import.json" || return 1
    count=$(jq '.nodes|length' "$XM_WORK_DIR/import.json") || return 1
    xm_info "导入文件：$1；节点数：$count；替换全部当前节点，核心版本保持。"
    xm_unlock
    xm_confirm '确认导入配置并替换当前节点？' || return 2
    xm_ready || return 1
    [[ $(jq -c . "$XM_STATE") == "$before" ]] || { xm_error '当前节点已被其他操作修改，请重新选择导入文件。'; return 1; }
    while IFS= read -r node; do
        port=$(jq -r .port <<< "$node")
        already_owned=$(jq -r --argjson port "$port" '.nodes|any(.port==$port)' "$XM_STATE")
        if [[ $already_owned != true ]]; then platform_port_available "$port" || { xm_error "导入端口冲突：$port"; return 1; }; fi
    done < <(jq -c '.nodes[]' "$XM_WORK_DIR/import.json")
    jq --arg version "$(jq -r .core_version "$XM_STATE")" '.core_version=$version' "$XM_WORK_DIR/import.json" > "$XM_WORK_DIR/state.json" || return 1
    state_apply "$XM_WORK_DIR/state.json" || return 1
    xm_success "已导入 $count 个节点：$1；各核心原运行状态已保留。"
}
xm_uninstall() {
    (($# == 0)) || { xm_usage_error 'uninstall 不接受参数。'; return 2; }
    xm_require_root && xm_need_commands jq flock && platform_detect && xm_installed && xm_lock || return 1
    xm_warning '完全卸载将清除本项目目录、节点、日志、核心、服务、账户、xy 和已记录且不共享的新增依赖。外部导出与证书文件保留。'
    xm_confirm '确认完全卸载？' || return 2
    [[ $XM_TX_ACTIVE == 0 ]] || { xm_error '当前事务尚未完成，拒绝卸载并保留现场。'; return 1; }
    xm_temp_cleanup; xm_work_end
    platform_clean_uninstall_preflight || return 1
    xm_service_call stop && xm_service_call disable || return 1
    if [[ -x $XM_EXTRA_BIN ]]; then xm_extra_service_call stop && xm_extra_service_call disable || return 1; fi
    if [[ -n $XM_LOCK_FD ]]; then platform_restart_schedule disable {XM_LOCK_FD}>&- || return 1; else platform_restart_schedule disable || return 1; fi
    platform_clean_uninstall || return 1
    xm_success '完全卸载完成；用户外部导出和证书保留。'
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
        edit) xm_edit "$@" ;;
        delete) xm_delete "$@" ;;
        share) xm_share "$@" ;;
        service) xm_service "$@" ;;
        schedule) xm_schedule "$@" ;;
        scheduled-restart) xm_scheduled_restart "$@" ;;
        logs) xm_logs "$@" ;;
        diagnose) xm_diagnose "$@" ;;
        export|backup) xm_backup "$@" ;;
        import|restore) xm_restore "$@" ;;
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
    case $1 in vless-reality) printf reality ;; vless-xhttp) printf xhttp ;; shadowsocks) printf ss2022 ;; vless-ws) printf 'vless(ws)' ;; socks5) printf socks5 ;; anytls) printf anytls ;; hysteria2) printf hy2 ;; tuicv5) printf tuicv5 ;; *) printf unknown ;; esac
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
        view) xm_menu_node_details "$XM_SELECTED_NODE" ;;
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
    local main_running=0 extra_running=0 failed=0
    xm_service_call status >/dev/null 2>&1 && main_running=1
    if [[ -x $XM_EXTRA_BIN ]]; then xm_extra_service_call status >/dev/null 2>&1 && extra_running=1; fi
    if [[ $main_running == 0 && $extra_running == 0 ]]; then xm_info '两个核心均未运行，跳过定时重启。'; return 0; fi
    xm_service_validate || return 1
    if [[ $main_running == 1 ]]; then xm_service_call restart && platform_health || failed=1; fi
    if [[ $extra_running == 1 ]]; then xm_extra_service_call restart && platform_extra_health || failed=1; fi
    if [[ $failed == 1 ]]; then xm_services_restore_running "$main_running" "$extra_running" || xm_error '定时重启回退失败。'; return 1; fi
    xm_success '已重启原本正在运行的核心，停止的核心保持停止。'
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
        candidate=$(printf '%s\0' "$XM_MENU_NODE" "$value" | jq -Rsc --arg field "$field" 'split("\u0000") as $data | ($data[0]|fromjson) | .[$field]=$data[1]') || return 1
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
    local XM_CHOICE XM_ID XM_NAME XM_PORT XM_ADDRESS XM_SNI XM_TARGET XM_PATH XM_MODE XM_PASSWORD XM_CERT XM_KEY XM_USERNAME
    local XM_MENU_NODE XM_INPUT suffix prefix default_id default_name default_port default_password type attempts
    xm_menu_ready || return 1
    xm_ui_heading '添加节点'
    xm_ui_item 1 'VLESS REALITY Vision'
    xm_ui_item 2 'VLESS XHTTP + REALITY'
    xm_ui_item 3 'Shadowsocks 2022'
    xm_ui_item 4 'VLESS WebSocket + TLS'
    xm_ui_item 5 'AnyTLS（辅助核心）'; xm_ui_item 6 'Hysteria2 / HY2（辅助核心）'
    xm_ui_item 7 'TUIC v5（辅助核心）'; xm_ui_item 8 'SOCKS5（账号密码认证）'
    printf '\n' >&2; xm_ui_item 0 '返回'
    xm_info '回车使用方括号中的默认值；任意字段输入 :q 取消。'
    while :; do
        xm_read XM_CHOICE '选择协议' '1' || return 2
        case $XM_CHOICE in 0) return 0 ;; 1) type=vless-reality; prefix=REALITY; break ;; 2) type=vless-xhttp; prefix=XHTTP; break ;; 3) type=shadowsocks; prefix=SS2022; break ;; 4) type=vless-ws; prefix=WS; break ;; 5) type=anytls; prefix=AnyTLS; break ;; 6) type=hysteria2; prefix=HY2; break ;; 7) type=tuicv5; prefix=TUIC; break ;; 8) type=socks5; prefix=SOCKS5; break ;; *) xm_error '请输入 0..8。' ;; esac
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
        socks5)
            xm_menu_draft "$type" "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" || return 1
            xm_menu_field XM_USERNAME username '认证用户名（3..64字母数字_-）' "$(jq -r .username <<< "$XM_MENU_NODE")" || return 2
            xm_menu_password XM_PASSWORD "$(jq -r .password <<< "$XM_MENU_NODE")" || return 2
            xm_dispatch add "$type" "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" "$XM_USERNAME" "$XM_PASSWORD"
            ;;
        vless-ws|anytls|hysteria2|tuicv5)
            xm_warning '需要有效证书及匹配私钥，SAN须包含TLS SNI；不自动跳过客户端证书验证。'
            while :; do
                xm_read XM_SNI 'TLS SNI（证书SAN中的域名/IP）' "$XM_ADDRESS" || return 2
                xm_read XM_CERT '证书绝对路径' '/etc/ssl/xray/fullchain.pem' || return 2
                xm_read XM_KEY '匹配私钥绝对路径' '/etc/ssl/xray/private.key' || return 2
                if [[ $type == vless-ws ]]; then
                    XM_PATH="/$(openssl rand -hex 8)" || return 1
                    xm_menu_draft "$type" "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" "$XM_SNI" "$XM_PATH" "$XM_CERT" "$XM_KEY" && break
                else
                    xm_menu_draft "$type" "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" "$XM_SNI" "$XM_CERT" "$XM_KEY" && break
                fi
                xm_warning 'TLS参数或证书无效，请重新输入；:q可取消。'
            done
            case $type in
                vless-ws)
                    xm_menu_field XM_PATH path 'WS路径（/开头，字母数字/_-）' "$XM_PATH" || return 2
                    xm_dispatch add "$type" "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" "$XM_SNI" "$XM_PATH" "$XM_CERT" "$XM_KEY" "$(jq -r .uuid <<< "$XM_MENU_NODE")" ;;
                anytls|hysteria2)
                    xm_menu_password XM_PASSWORD "$(jq -r .password <<< "$XM_MENU_NODE")" || return 2
                    xm_dispatch add "$type" "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" "$XM_SNI" "$XM_CERT" "$XM_KEY" "$XM_PASSWORD" ;;
                tuicv5)
                    xm_menu_password XM_PASSWORD "$(jq -r .password <<< "$XM_MENU_NODE")" || return 2
                    xm_dispatch add "$type" "$XM_ID" "$XM_NAME" "$XM_PORT" "$XM_ADDRESS" "$XM_SNI" "$XM_CERT" "$XM_KEY" "$(jq -r .uuid <<< "$XM_MENU_NODE")" "$XM_PASSWORD" ;;
            esac
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
        xm_ui_pair 11 '导出配置' 12 '导入配置'
        printf '\n%s危险操作%s\n' "$XM_UI_RED" "$XM_UI_RESET" >&2
        xm_ui_item 13 '完全卸载'
    else
        xm_ui_heading '核心管理'
        xm_ui_item 1 '安装核心'; xm_ui_item 2 '选择版本并升级'; xm_ui_item 3 '核心回退'
        xm_ui_heading '节点管理'
        xm_ui_item 4 '查看节点'; xm_ui_item 5 '添加节点'; xm_ui_item 6 '删除节点'; xm_ui_item 7 '分享链接'
        xm_ui_heading '运行维护'
        xm_ui_item 8 '服务操作'; xm_ui_item 9 '查看日志'; xm_ui_item 10 '运行诊断'
        xm_ui_heading '数据管理'
        xm_ui_item 11 '导出配置'; xm_ui_item 12 '导入配置'
        xm_ui_heading '危险操作'; xm_ui_item 13 '完全卸载'
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
            11) xm_menu_ready && xm_read XM_FILE '导出配置绝对路径' "/root/xray-manager-export-$(date +%Y%m%d-%H%M%S).json" && xm_dispatch export "$XM_FILE" ;;
            12) xm_menu_ready && xm_read XM_FILE '导入配置绝对路径' '' '选择已有导出文件；:q 取消' && xm_dispatch import "$XM_FILE" ;;
            13) xm_dispatch uninstall && { xm_pause; return 0; } ;;
            *) xm_error '选择无效，请输入菜单编号。' ;;
        esac
        xm_pause
        # Non-TTY input is never consumed by the return prompt.
    done
}
xm_main() {
    umask 077
    xm_ui_init
    if [[ ${1:-} == --yes ]]; then XM_YES=1; shift; fi
    if [[ ${1:-} == -- ]]; then shift; fi
    xm_dispatch "$@"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then xm_main "$@"; exit $?; fi

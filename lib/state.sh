#!/usr/bin/env bash
# JSON state and rollback transactions; no work occurs when sourced.
XM_TX_ACTIVE=0
XM_TX_RUNNING=0
XM_TX_CORE=0
XM_TX_HISTORY=0
XM_TX_EXTRA_RUNNING=0
XM_TX_EXTRA_AVAILABLE=0
XM_TX_EXTRA_ENABLED=0
XM_TX_EXTRA_PREPARED=0
XM_TX_EXTRA_HAD_BIN=1
XM_TX_EXTRA_HAD_SERVICE=1

state_validate() {
    local file=$1 mode=${2:-strict} node bytes
    case $mode in strict|maintenance) ;; *) xm_error '未知配置验证模式。'; return 2 ;; esac
    [[ -f $file && ! -L $file ]] || { xm_error '状态必须是普通 JSON 文件。'; return 1; }
    bytes=$(wc -c < "$file") || return 1
    ((bytes <= 16777216)) || { xm_error '配置文件超过 16 MiB。'; return 1; }
    jq -e 'type == "object" and ((keys | sort) == ["core_version","nodes","schema_version"]) and .schema_version == 1 and (.core_version | type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and (.nodes | type == "array")' "$file" >/dev/null 2>&1 || {
        xm_error '状态结构或 schema_version 不受支持。'; return 1;
    }
    while IFS= read -r node; do protocol_validate_node "$node" "$mode" || return 1; done < <(jq -c '.nodes[]' "$file")
    jq -e '.nodes as $nodes | ["id","name","port","uuid","private_key","public_key","short_id","password","username","path"] | all(. as $key | ($nodes | map(.[$key]) | map(select(.!=null))) as $values | ($values|unique|length)==($values|length))' "$file" >/dev/null || {
        xm_error '节点 ID、名称、端口、凭据或路径重复。'; return 1;
    }
}
# Only edit/delete may preserve exact existing nodes with expired TLS.
# Changed/new nodes remain strict; identity alone never grants an exception.
state_validate_maintenance_candidate() {
    local candidate=$1 node
    state_validate "$XM_STATE" maintenance && state_validate "$candidate" maintenance || return 1
    jq -e --slurpfile old "$XM_STATE" '.core_version==$old[0].core_version' "$candidate" >/dev/null || return 1
    while IFS= read -r node; do
        if ! jq -e --slurpfile old "$XM_STATE" '. as $node | any($old[0].nodes[]; .==$node)' <<< "$node" >/dev/null; then
            protocol_validate_node "$node" strict || return 1
        fi
    done < <(jq -c '.nodes[]' "$candidate")
}
state_empty() { jq -n --arg version "$1" '{schema_version:1,core_version:$version,nodes:[]}'; }
state_native_validate() {
    local core=$1 config=$2
    if ! "$core" run -test -config "$config" >"$XM_TEMP_DIR/native-test.log" 2>&1; then
        [[ -d $XM_LOG ]] && xm_atomic_copy "$XM_TEMP_DIR/native-test.log" "$XM_LOG/last-error.log" 0600
        xm_error "Xray 原生配置校验失败；诊断位于 $XM_LOG/last-error.log。"; return 1
    fi
}
state_extra_native_validate() {
    local config=$1
    if ! "$XM_EXTRA_BIN" check -c "$config" > "$XM_TEMP_DIR/extra-native-test.log" 2>&1; then
        [[ -d $XM_LOG ]] && xm_atomic_copy "$XM_TEMP_DIR/extra-native-test.log" "$XM_LOG/last-extra-error.log" 0600
        xm_error "辅助核心原生配置校验失败：$XM_LOG/last-extra-error.log"; return 1
    fi
}
state_save_diagnostic() {
    local message=$1
    if [[ -d $XM_LOG && ! -L $XM_LOG/last-error.log ]]; then
        (umask 077; printf '%s\n' "$message" > "$XM_LOG/last-error.log")
    fi
}
state_rollback() {
    local failed=0
    [[ $XM_TX_ACTIVE == 1 ]] || return 0
    xm_service_call stop >/dev/null 2>&1 || failed=1
    if [[ $XM_TX_EXTRA_AVAILABLE == 1 ]]; then xm_extra_service_call stop >/dev/null 2>&1 || failed=1; fi
    if [[ -f $XM_TEMP_DIR/old-state.json ]]; then xm_atomic_copy "$XM_TEMP_DIR/old-state.json" "$XM_STATE" || failed=1; else rm -f -- "$XM_STATE" || failed=1; fi
    if [[ -f $XM_TEMP_DIR/old-config.json ]]; then xm_atomic_copy "$XM_TEMP_DIR/old-config.json" "$XM_CONFIG" || failed=1; else rm -f -- "$XM_CONFIG" || failed=1; fi
    if [[ -f $XM_TEMP_DIR/old-extra.json ]]; then xm_atomic_copy "$XM_TEMP_DIR/old-extra.json" "$XM_EXTRA_CONFIG" || failed=1; else rm -f -- "$XM_EXTRA_CONFIG" || failed=1; fi
    if [[ $XM_TX_CORE == 1 ]]; then
        if [[ -f $XM_TEMP_DIR/old-xray ]]; then xm_atomic_copy "$XM_TEMP_DIR/old-xray" "$XM_BIN" 0755 || failed=1; else rm -f -- "$XM_BIN" || failed=1; fi
    fi
    if [[ $XM_TX_HISTORY == 1 ]]; then
        if [[ -f $XM_TEMP_DIR/old-previous-xray ]]; then xm_atomic_copy "$XM_TEMP_DIR/old-previous-xray" "$XM_HOME/bin/xray.previous" 0755 || failed=1; else rm -f -- "$XM_HOME/bin/xray.previous" || failed=1; fi
        if [[ -f $XM_TEMP_DIR/old-previous-version ]]; then xm_atomic_copy "$XM_TEMP_DIR/old-previous-version" "$XM_ETC/core.previous-version" 0600 || failed=1; else rm -f -- "$XM_ETC/core.previous-version" || failed=1; fi
    fi
    if [[ $XM_TX_RUNNING == 1 ]]; then xm_service_call start >/dev/null 2>&1 && platform_health >/dev/null 2>&1 || failed=1; fi
    if [[ $XM_TX_EXTRA_AVAILABLE == 1 ]]; then
        if [[ $XM_TX_EXTRA_ENABLED == 1 ]]; then xm_extra_service_call enable >/dev/null 2>&1 || failed=1; else xm_extra_service_call disable >/dev/null 2>&1 || failed=1; fi
    fi
    if [[ $XM_TX_EXTRA_RUNNING == 1 ]]; then xm_extra_service_call start >/dev/null 2>&1 && platform_extra_health >/dev/null 2>&1 || failed=1; fi
    if [[ $XM_TX_EXTRA_PREPARED == 1 ]]; then platform_extra_discard_new "$XM_TX_EXTRA_HAD_BIN" "$XM_TX_EXTRA_HAD_SERVICE" || failed=1; fi
    XM_TX_EXTRA_PREPARED=0
    XM_TX_ACTIVE=0
    if [[ $failed == 1 ]]; then
        state_save_diagnostic '自动回退未完全成功，请检查受管文件及 xray-manager 服务。'
        xm_error "自动回退未完全成功。保留事务现场：$XM_TEMP_DIR"; XM_TEMP_DIR=; return 1
    fi
    xm_warning '已恢复操作前的配置、核心与各服务运行状态。'
}
state_apply() {
    local candidate=$1 new_core=${2:-} validate_core=${2:-$XM_BIN} mode=${3:-strict} failed=0 has_extra=0 old_has_extra=0
    XM_TX_EXTRA_PREPARED=0; XM_TX_EXTRA_HAD_BIN=1; XM_TX_EXTRA_HAD_SERVICE=1
    case $mode in
        strict) state_validate "$candidate" || return 1 ;;
        maintenance) [[ -z $new_core ]] && state_validate_maintenance_candidate "$candidate" || return 1 ;;
        *) xm_error '未知事务验证模式。'; return 2 ;;
    esac
    xm_private_temp || return 1
    if ! cp -- "$candidate" "$XM_TEMP_DIR/new-state.json" || ! protocol_generate "$XM_TEMP_DIR/new-state.json" "$XM_TEMP_DIR/new-config.json" "$mode" || ! state_native_validate "$validate_core" "$XM_TEMP_DIR/new-config.json"; then
        xm_temp_cleanup; return 1
    fi
    protocol_generate_extra "$XM_TEMP_DIR/new-state.json" "$XM_TEMP_DIR/new-extra.json" "$mode" || { xm_temp_cleanup; return 1; }
    XM_TX_EXTRA_AVAILABLE=0
    [[ ! -x $XM_EXTRA_BIN ]] || XM_TX_EXTRA_AVAILABLE=1
    if protocol_has_extra "$XM_TEMP_DIR/new-state.json"; then
        has_extra=1
        XM_TX_EXTRA_HAD_BIN=0; XM_TX_EXTRA_HAD_SERVICE=0
        [[ ! -e $XM_EXTRA_BIN && ! -L $XM_EXTRA_BIN ]] || XM_TX_EXTRA_HAD_BIN=1
        platform_extra_installed && XM_TX_EXTRA_HAD_SERVICE=1
        platform_extra_ensure || { xm_temp_cleanup; return 1; }
        XM_TX_EXTRA_PREPARED=1
        if ! state_extra_native_validate "$XM_TEMP_DIR/new-extra.json" || ! platform_extra_install_service; then
            platform_extra_discard_new "$XM_TX_EXTRA_HAD_BIN" "$XM_TX_EXTRA_HAD_SERVICE" || xm_error '新辅助核心资源撤销失败，请诊断。'
            XM_TX_EXTRA_PREPARED=0; xm_temp_cleanup; return 1
        fi
        XM_TX_EXTRA_AVAILABLE=1
    fi
    XM_TX_EXTRA_ENABLED=0
    if [[ $XM_TX_EXTRA_AVAILABLE == 1 ]]; then platform_extra_enabled && XM_TX_EXTRA_ENABLED=1; fi
    if [[ -f $XM_STATE ]] && protocol_has_extra "$XM_STATE"; then old_has_extra=1; fi
    XM_TX_RUNNING=0; XM_TX_EXTRA_RUNNING=0; XM_TX_CORE=0; XM_TX_HISTORY=0
    xm_service_call status >/dev/null 2>&1 && XM_TX_RUNNING=1
    if [[ $XM_TX_EXTRA_AVAILABLE == 1 ]]; then xm_extra_service_call status >/dev/null 2>&1 && XM_TX_EXTRA_RUNNING=1; fi
    if [[ -f $XM_STATE ]]; then cp -p -- "$XM_STATE" "$XM_TEMP_DIR/old-state.json" || failed=1; fi
    if [[ -f $XM_CONFIG ]]; then cp -p -- "$XM_CONFIG" "$XM_TEMP_DIR/old-config.json" || failed=1; fi
    if [[ -f $XM_EXTRA_CONFIG ]]; then cp -p -- "$XM_EXTRA_CONFIG" "$XM_TEMP_DIR/old-extra.json" || failed=1; fi
    if [[ -n $new_core ]]; then
        XM_TX_CORE=1
        xm_path_no_links "$XM_HOME/bin/xray.previous" && xm_path_no_links "$XM_ETC/core.previous-version" || failed=1
        if [[ -f $XM_BIN ]]; then cp -p -- "$XM_BIN" "$XM_TEMP_DIR/old-xray" || failed=1; fi
        if [[ -f $XM_HOME/bin/xray.previous ]]; then cp -p -- "$XM_HOME/bin/xray.previous" "$XM_TEMP_DIR/old-previous-xray" || failed=1; fi
        if [[ -f $XM_ETC/core.previous-version ]]; then cp -p -- "$XM_ETC/core.previous-version" "$XM_TEMP_DIR/old-previous-version" || failed=1; fi
    fi
    if [[ $failed == 1 ]]; then
        if [[ $XM_TX_EXTRA_PREPARED == 1 ]]; then platform_extra_discard_new "$XM_TX_EXTRA_HAD_BIN" "$XM_TX_EXTRA_HAD_SERVICE" || true; fi
        XM_TX_EXTRA_PREPARED=0; xm_temp_cleanup; return 1
    fi
    XM_TX_ACTIVE=1
    if [[ $XM_TX_RUNNING == 1 ]]; then xm_service_call stop >/dev/null 2>&1 || failed=1; fi
    if [[ $XM_TX_EXTRA_RUNNING == 1 ]]; then xm_extra_service_call stop >/dev/null 2>&1 || failed=1; fi
    if [[ $failed == 0 && -n $new_core ]]; then xm_atomic_copy "$new_core" "$XM_BIN" 0755 || failed=1; fi
    if [[ $failed == 0 ]]; then xm_atomic_copy "$XM_TEMP_DIR/new-config.json" "$XM_CONFIG" || failed=1; fi
    if [[ $failed == 0 ]]; then xm_atomic_copy "$XM_TEMP_DIR/new-extra.json" "$XM_EXTRA_CONFIG" || failed=1; fi
    if [[ $failed == 0 ]]; then xm_atomic_copy "$XM_TEMP_DIR/new-state.json" "$XM_STATE" || failed=1; fi
    if [[ $failed == 0 && $XM_TX_RUNNING == 1 ]]; then
        xm_service_call start >/dev/null 2>&1 && platform_health >/dev/null 2>&1 || failed=1
    fi
    if [[ $failed == 0 && $XM_TX_EXTRA_AVAILABLE == 1 ]]; then
        if [[ $has_extra == 0 ]]; then xm_extra_service_call disable >/dev/null 2>&1 || failed=1
        elif [[ $old_has_extra == 0 ]]; then xm_extra_service_call enable >/dev/null 2>&1 || failed=1; fi
    fi
    if [[ $failed == 0 && $has_extra == 1 && ( $XM_TX_EXTRA_RUNNING == 1 || ( $old_has_extra == 0 && $XM_TX_RUNNING == 1 ) ) ]]; then
        xm_extra_service_call start >/dev/null 2>&1 && platform_extra_health >/dev/null 2>&1 || failed=1
    fi
    if [[ $failed == 1 ]]; then
        xm_error '配置切换或服务健康检查失败，正在回退。'
        state_rollback; xm_temp_cleanup; return 1
    fi
    if [[ -n $new_core && -f $XM_TEMP_DIR/old-xray && -f $XM_TEMP_DIR/old-state.json ]]; then
        XM_TX_HISTORY=1
        jq -r '.core_version' "$XM_TEMP_DIR/old-state.json" > "$XM_TEMP_DIR/previous-version" || failed=1
        xm_atomic_copy "$XM_TEMP_DIR/old-xray" "$XM_HOME/bin/xray.previous" 0755 || failed=1
        xm_atomic_copy "$XM_TEMP_DIR/previous-version" "$XM_ETC/core.previous-version" 0600 || failed=1
    fi
    if [[ $failed == 1 ]]; then state_rollback; xm_temp_cleanup; return 1; fi
    XM_TX_ACTIVE=0; XM_TX_EXTRA_PREPARED=0
    xm_temp_cleanup
}
state_exit_cleanup() {
    local status=$1
    [[ $XM_TX_ACTIVE == 0 ]] || state_rollback
    xm_temp_cleanup
    xm_unlock
    return "$status"
}

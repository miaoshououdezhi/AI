#!/usr/bin/env bash
# JSON state and rollback transactions; no work occurs when sourced.
XM_TX_ACTIVE=0
XM_TX_RUNNING=0
XM_TX_CORE=0
XM_TX_HISTORY=0

state_validate() {
    local file=$1 node
    [[ -f $file && ! -L $file ]] || { xm_error '状态必须是普通 JSON 文件。'; return 1; }
    jq -e 'type == "object" and ((keys | sort) == ["core_version","nodes","schema_version"]) and .schema_version == 1 and (.core_version | type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and (.nodes | type == "array")' "$file" >/dev/null 2>&1 || {
        xm_error '状态结构或 schema_version 不受支持。'; return 1;
    }
    while IFS= read -r node; do protocol_validate_node "$node" || return 1; done < <(jq -c '.nodes[]' "$file")
    jq -e '(.nodes | map(.id) | unique | length) == (.nodes | length) and (.nodes | map(.port) | unique | length) == (.nodes | length)' "$file" >/dev/null || {
        xm_error '节点 ID 或端口重复。'; return 1;
    }
}
state_empty() { jq -n --arg version "$1" '{schema_version:1,core_version:$version,nodes:[]}'; }
state_native_validate() {
    local core=$1 config=$2
    if ! "$core" run -test -config "$config" >"$XM_TEMP_DIR/native-test.log" 2>&1; then
        [[ -d $XM_LOG ]] && xm_atomic_copy "$XM_TEMP_DIR/native-test.log" "$XM_LOG/last-error.log" 0600
        xm_error "Xray 原生配置校验失败；诊断位于 $XM_LOG/last-error.log。"; return 1
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
    if [[ -f $XM_TEMP_DIR/old-state.json ]]; then xm_atomic_copy "$XM_TEMP_DIR/old-state.json" "$XM_STATE" || failed=1; else rm -f -- "$XM_STATE" || failed=1; fi
    if [[ -f $XM_TEMP_DIR/old-config.json ]]; then xm_atomic_copy "$XM_TEMP_DIR/old-config.json" "$XM_CONFIG" || failed=1; else rm -f -- "$XM_CONFIG" || failed=1; fi
    if [[ $XM_TX_CORE == 1 ]]; then
        if [[ -f $XM_TEMP_DIR/old-xray ]]; then xm_atomic_copy "$XM_TEMP_DIR/old-xray" "$XM_BIN" 0755 || failed=1; else rm -f -- "$XM_BIN" || failed=1; fi
    fi
    if [[ $XM_TX_HISTORY == 1 ]]; then
        if [[ -f $XM_TEMP_DIR/old-previous-xray ]]; then xm_atomic_copy "$XM_TEMP_DIR/old-previous-xray" "$XM_HOME/bin/xray.previous" 0755 || failed=1; else rm -f -- "$XM_HOME/bin/xray.previous" || failed=1; fi
        if [[ -f $XM_TEMP_DIR/old-previous-version ]]; then xm_atomic_copy "$XM_TEMP_DIR/old-previous-version" "$XM_ETC/core.previous-version" 0600 || failed=1; else rm -f -- "$XM_ETC/core.previous-version" || failed=1; fi
    fi
    if [[ $XM_TX_RUNNING == 1 ]]; then xm_service_call start >/dev/null 2>&1 && platform_health >/dev/null 2>&1 || failed=1; fi
    XM_TX_ACTIVE=0
    if [[ $failed == 1 ]]; then
        state_save_diagnostic '自动回退未完全成功，请检查受管文件及 xray-manager 服务。'
        xm_error "自动回退未完全成功。保留事务现场：$XM_TEMP_DIR"; XM_TEMP_DIR=; return 1
    fi
    xm_info '已恢复操作前的配置、核心与服务运行状态。'
}
state_apply() {
    local candidate=$1 new_core=${2:-} validate_core=${2:-$XM_BIN} failed=0
    state_validate "$candidate" || return 1
    xm_private_temp || return 1
    if ! cp -- "$candidate" "$XM_TEMP_DIR/new-state.json" || ! protocol_generate "$XM_TEMP_DIR/new-state.json" "$XM_TEMP_DIR/new-config.json" || ! state_native_validate "$validate_core" "$XM_TEMP_DIR/new-config.json"; then
        xm_temp_cleanup; return 1
    fi
    XM_TX_RUNNING=0; XM_TX_CORE=0; XM_TX_HISTORY=0
    xm_service_call status >/dev/null 2>&1 && XM_TX_RUNNING=1
    if [[ -f $XM_STATE ]]; then cp -p -- "$XM_STATE" "$XM_TEMP_DIR/old-state.json" || failed=1; fi
    if [[ -f $XM_CONFIG ]]; then cp -p -- "$XM_CONFIG" "$XM_TEMP_DIR/old-config.json" || failed=1; fi
    if [[ -n $new_core ]]; then
        XM_TX_CORE=1
        xm_path_no_links "$XM_HOME/bin/xray.previous" && xm_path_no_links "$XM_ETC/core.previous-version" || failed=1
        if [[ -f $XM_BIN ]]; then cp -p -- "$XM_BIN" "$XM_TEMP_DIR/old-xray" || failed=1; fi
        if [[ -f $XM_HOME/bin/xray.previous ]]; then cp -p -- "$XM_HOME/bin/xray.previous" "$XM_TEMP_DIR/old-previous-xray" || failed=1; fi
        if [[ -f $XM_ETC/core.previous-version ]]; then cp -p -- "$XM_ETC/core.previous-version" "$XM_TEMP_DIR/old-previous-version" || failed=1; fi
    fi
    if [[ $failed == 1 ]]; then xm_temp_cleanup; return 1; fi
    XM_TX_ACTIVE=1
    if [[ $XM_TX_RUNNING == 1 ]]; then xm_service_call stop >/dev/null 2>&1 || failed=1; fi
    if [[ $failed == 0 && -n $new_core ]]; then xm_atomic_copy "$new_core" "$XM_BIN" 0755 || failed=1; fi
    if [[ $failed == 0 ]]; then xm_atomic_copy "$XM_TEMP_DIR/new-config.json" "$XM_CONFIG" || failed=1; fi
    if [[ $failed == 0 ]]; then xm_atomic_copy "$XM_TEMP_DIR/new-state.json" "$XM_STATE" || failed=1; fi
    if [[ $failed == 0 && $XM_TX_RUNNING == 1 ]]; then
        xm_service_call start >/dev/null 2>&1 && platform_health >/dev/null 2>&1 || failed=1
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
    XM_TX_ACTIVE=0
    xm_temp_cleanup
}
state_exit_cleanup() {
    local status=$1
    [[ $XM_TX_ACTIVE == 0 ]] || state_rollback
    xm_temp_cleanup
    xm_unlock
    return "$status"
}

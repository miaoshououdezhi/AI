#!/usr/bin/env bash
# Meaningful transaction tests with platform service failure injection.
set -u
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then printf '%s\n' 'SKIP: test-shell needs Bash >=4.4' >&2; exit 77; fi
REPO=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
ROOT=$(mktemp -d)
export XM_ROOT="$ROOT"
source "$REPO/lib/common.sh"
source "$REPO/lib/state.sh"
trap 'state_exit_cleanup $?; rm -rf -- "$ROOT"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
mkdir -p "$XM_HOME/bin" "$XM_ETC" "$XM_DATA" "$XM_LOG"
for directory in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG"; do printf 'xray-manager:1\n' > "$directory/.xray-manager-owned"; done
xm_need_commands jq flock || fail 'missing tools'
xm_lock || fail 'lock first owner'
if bash -c 'source "$1/lib/common.sh"; xm_lock' -- "$REPO" >/dev/null 2>&1; then fail 'concurrent lock accepted'; fi
pass 'exclusive lock rejects competing process'
protocol_validate_node() { jq -e '(.id|type=="string") and (.port|type=="number")' <<< "$1" >/dev/null; }
protocol_has_extra() { return 1; }
protocol_generate_extra() { printf '{"inbounds":[]}\n' > "$2"; }
protocol_generate() { jq '{log:{loglevel:"warning"},inbounds:[],outbounds:[],test_nodes:.nodes}' "$1" > "$2"; }
MOCK_RUNNING=1
MOCK_START_FAILURE=0
MOCK_HEALTH_FAILURE=0
platform_service() {
    case $1 in
        status) [[ $MOCK_RUNNING == 1 ]] ;;
        stop) MOCK_RUNNING=0 ;;
        start|restart)
            if ((MOCK_START_FAILURE > 0)); then MOCK_START_FAILURE=$((MOCK_START_FAILURE - 1)); return 1; fi
            MOCK_RUNNING=1 ;;
        *) return 1 ;;
    esac
}
platform_health() {
    if ((MOCK_HEALTH_FAILURE > 0)); then MOCK_HEALTH_FAILURE=$((MOCK_HEALTH_FAILURE - 1)); return 1; fi
    [[ $MOCK_RUNNING == 1 ]]
}
cat > "$XM_BIN" <<'CORE'
#!/usr/bin/env bash
if [[ ${MOCK_NATIVE_FAIL:-0} == 1 ]]; then exit 1; fi
exit 0
CORE
chmod 0755 "$XM_BIN"
state_empty v26.3.27 > "$XM_STATE"
protocol_generate "$XM_STATE" "$XM_CONFIG"
cp "$XM_STATE" "$ROOT/old-state"
cp "$XM_CONFIG" "$ROOT/old-config"
jq '.nodes=[{id:"first",port:1443}]' "$XM_STATE" > "$ROOT/candidate"
state_apply "$ROOT/candidate" || fail 'valid state apply'
[[ $MOCK_RUNNING == 1 ]] || fail 'running state not preserved'
jq -e '.nodes[0].id=="first"' "$XM_STATE" >/dev/null || fail 'candidate not persisted'
pass 'validated configuration replacement preserves running service'
cp "$XM_STATE" "$ROOT/valid-state"
cp "$XM_CONFIG" "$ROOT/valid-config"
jq '.nodes=[{id:"second",port:2443}]' "$XM_STATE" > "$ROOT/candidate"
export MOCK_NATIVE_FAIL=1
if state_apply "$ROOT/candidate"; then fail 'native rejection accepted'; fi
unset MOCK_NATIVE_FAIL
cmp "$XM_STATE" "$ROOT/valid-state" && cmp "$XM_CONFIG" "$ROOT/valid-config" || fail 'native validation mutated active files'
pass 'native validation failure leaves active files intact'
MOCK_START_FAILURE=1
if state_apply "$ROOT/candidate"; then fail 'failed startup accepted'; fi
cmp "$XM_STATE" "$ROOT/valid-state" && cmp "$XM_CONFIG" "$ROOT/valid-config" || fail 'startup failure did not restore files'
[[ $MOCK_RUNNING == 1 ]] || fail 'startup rollback did not restore service'
pass 'startup failure restores configuration and previous running service'
MOCK_HEALTH_FAILURE=1
if state_apply "$ROOT/candidate"; then fail 'failed health accepted'; fi
cmp "$XM_STATE" "$ROOT/valid-state" && cmp "$XM_CONFIG" "$ROOT/valid-config" || fail 'health failure did not restore files'
[[ $MOCK_RUNNING == 1 ]] || fail 'health rollback did not restore service'
pass 'health failure restores configuration and previous running service'
MOCK_RUNNING=0
state_apply "$ROOT/candidate" || fail 'stopped state apply'
[[ $MOCK_RUNNING == 0 ]] || fail 'stopped service automatically started'
pass 'stopped service remains stopped during configuration changes'
cp "$XM_BIN" "$ROOT/old-xray"
printf '\n# new version\n' >> "$ROOT/old-xray"
chmod 0755 "$ROOT/old-xray"
jq '.core_version="v26.4.1"' "$XM_STATE" > "$ROOT/core-state"
state_apply "$ROOT/core-state" "$ROOT/old-xray" || fail 'core upgrade'
[[ $(cat "$XM_ETC/core.previous-version") == v26.3.27 ]] || fail 'previous version not recorded'
[[ -x $XM_HOME/bin/xray.previous ]] || fail 'previous core not recorded'
pass 'core upgrade records previous executable and version'
cp "$XM_STATE" "$ROOT/upgrade-state"
cp "$XM_BIN" "$ROOT/upgrade-core"
MOCK_RUNNING=1; MOCK_HEALTH_FAILURE=1
jq '.core_version="v26.5.1"' "$XM_STATE" > "$ROOT/core-state"
if state_apply "$ROOT/core-state" "$XM_HOME/bin/xray.previous"; then fail 'core health failure accepted'; fi
cmp "$XM_STATE" "$ROOT/upgrade-state" && cmp "$XM_BIN" "$ROOT/upgrade-core" || fail 'core rollback failed'
pass 'failed core switch restores previous core and state'
# Fail exactly once after replacing the previous executable but before its version file.
cp "$XM_HOME/bin/xray.previous" "$ROOT/history-core"
cp "$XM_ETC/core.previous-version" "$ROOT/history-version"
cp "$XM_STATE" "$ROOT/history-state"
cp "$XM_BIN" "$ROOT/history-active-core"
ORIGINAL_LOCK_FD=$XM_LOCK_FD
# Only the fixed, trusted adjacent common library is used to wrap fault injection.
# shellcheck disable=SC1090
source <(sed 's/^xm_atomic_copy()/xm_atomic_copy_original()/' "$REPO/lib/common.sh")
XM_LOCK_FD=$ORIGINAL_LOCK_FD
MOCK_HISTORY_FAILURE=1
xm_atomic_copy() {
    if [[ $2 == "$XM_ETC/core.previous-version" && $MOCK_HISTORY_FAILURE == 1 ]]; then MOCK_HISTORY_FAILURE=0; return 1; fi
    xm_atomic_copy_original "$@"
}
jq '.core_version="v26.6.1"' "$XM_STATE" > "$ROOT/core-state"
if state_apply "$ROOT/core-state" "$ROOT/old-xray"; then fail 'history metadata failure accepted'; fi
cmp "$XM_HOME/bin/xray.previous" "$ROOT/history-core" && cmp "$XM_ETC/core.previous-version" "$ROOT/history-version" || fail 'rollback history pair damaged'
cmp "$XM_STATE" "$ROOT/history-state" && cmp "$XM_BIN" "$ROOT/history-active-core" || fail 'active pair damaged after history failure'
[[ $MOCK_RUNNING == 1 ]] || fail 'history rollback did not restore running service'
pass 'history metadata failure restores active and previous binary/version pairs'
printf '{"schema_version":2,"core_version":"v26.3.27","nodes":[]}\n' > "$ROOT/bad-state"
if state_validate "$ROOT/bad-state"; then fail 'unknown schema accepted'; fi
jq '.nodes=[{id:"same",port:443},{id:"same",port:443}]' "$XM_STATE" > "$ROOT/bad-state"
if state_validate "$ROOT/bad-state"; then fail 'duplicate nodes accepted'; fi
pass 'unknown schema and duplicate IDs/ports rejected'
ln -s "$ROOT/target" "$ROOT/link"
if xm_atomic_copy "$XM_STATE" "$ROOT/link"; then fail 'symlink overwrite accepted'; fi
[[ ! -e $ROOT/target ]] || fail 'symlink target created'
pass 'atomic copy rejects symlink destination'
xm_unlock
XM_ROOT="$ROOT" bash "$REPO/xray-manager.sh" help > "$ROOT/help" || fail 'CLI help'
rg_cmd='grep'
"$rg_cmd" -q 'share ID' "$ROOT/help" || fail 'missing share command'
if XM_ROOT="$ROOT" bash "$REPO/xray-manager.sh" unknown >/dev/null 2>&1; then fail 'unknown command accepted'; fi
XM_ROOT="$ROOT" bash "$REPO/xray-manager.sh" menu < /dev/null >/dev/null 2>&1 || fail 'menu EOF did not exit'
pass 'help, unknown command, and EOF handled'

# Regression: replacing a managed library directory with a symlink must never
# delete an outside file or change service state. Only a trusted function is loaded.
(
    # shellcheck disable=SC1090
    source "$REPO/lib/platform.sh"
    # shellcheck disable=SC1090
    source <(sed -n '/^xm_uninstall() {/,/^}/p' "$REPO/xray-manager.sh")
    xm_ready() { return 0; }
    xm_confirm() { return 0; }
    xm_service_call() { touch "$ROOT/service-touched"; }
    platform_remove_service() { touch "$ROOT/service-touched"; }
    for directory in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG"; do
        printf 'xray-manager:1\n' > "$directory/.xray-manager-owned"
    done
    mkdir -p "$ROOT/foreign-lib"
    printf 'retain\n' > "$ROOT/foreign-lib/common.sh"
    ln -s "$ROOT/foreign-lib" "$XM_HOME/lib"
    if xm_uninstall; then fail 'uninstall accepted symlink ancestor'; fi
    [[ $(cat "$ROOT/foreign-lib/common.sh") == retain && ! -e $ROOT/service-touched ]] || fail 'uninstall crossed ownership boundary'
) || fail 'uninstall ancestor-symlink regression block failed'
pass 'uninstall refuses ancestor symlink before service changes or deletion'

# Legacy removal uses real state_apply transactions with the existing mock core
# and service. Only the retired type discriminator is read; expired certs need
# no protocol validator and are never accessed.
(
    # shellcheck disable=SC1090
    source <(sed -n '/^xm_version_valid() /p; /^xm_usage_error() /p; /^xm_work_begin() {/,/^}/p; /^xm_work_end() {/,/^}/p; /^xm_retire_trojan() {/,/^}/p; /^xm_install() {/,/^}/p' "$REPO/xray-manager.sh") || fail 'migration helper loading'
    export XM_WORK_DIR=
    protocol_validate_node() { jq -e '.type=="shadowsocks" and (.id|type=="string") and (.port|type=="number")' <<< "$1" >/dev/null; }
    xm_installed() { return 0; }
    platform_detect() { return 0; }
    platform_shortcut_preflight() { return 0; }
    platform_dependencies_snapshot() { return 0; }
    platform_dependencies() { return 0; }
    platform_prepare() { return 0; }
    platform_install_service() { return 0; }
    platform_shortcut_install() { return 0; }
    xm_install_code() { printf 'updated\n' > "$ROOT/migration-code"; }
    make_legacy() {
        jq -n '{schema_version:1,core_version:"v26.3.27",nodes:[{id:"keep",type:"shadowsocks",port:3443},{id:"retired",type:"trojan",port:2443,cert:"/expired/no-certificate",key:"/expired/no-key",password:"private-test-fixture"}]}' > "$XM_STATE"
        protocol_generate "$XM_STATE" "$XM_CONFIG"
        cp "$XM_STATE" "$ROOT/migration-old-state"
        cp "$XM_CONFIG" "$ROOT/migration-old-config"
    }
    make_legacy
    MOCK_RUNNING=1; MOCK_HEALTH_FAILURE=0
    xm_install || fail 'retired node migration'
    jq -e '.core_version=="v26.3.27" and (.nodes|length)==1 and .nodes[0].id=="keep"' "$XM_STATE" >/dev/null || fail 'migration removed supported nodes'
    [[ $MOCK_RUNNING == 1 && -e $ROOT/migration-code ]] || fail 'migration running state/code order'
    backups=("$XM_ETC"/trojan-retired-backup.*)
    [[ ${#backups[@]} == 1 ]] || fail 'missing unique retirement backup'
    cmp "${backups[0]}" "$ROOT/migration-old-state" || fail 'retirement backup not complete'
    [[ $(stat -c %a "${backups[0]}") == 600 ]] || fail 'retirement backup not private'
    xm_work_end; xm_unlock
    rm -f "$ROOT/migration-code"
    make_legacy
    MOCK_RUNNING=1; MOCK_HEALTH_FAILURE=1
    if xm_install; then fail 'migration health failure accepted'; fi
    cmp "$XM_STATE" "$ROOT/migration-old-state" && cmp "$XM_CONFIG" "$ROOT/migration-old-config" || fail 'retirement rollback changed active files'
    [[ $MOCK_RUNNING == 1 && ! -e $ROOT/migration-code ]] || fail 'failed migration updated code/stopped core'
    xm_work_end; xm_unlock
    backups=("$XM_ETC"/trojan-retired-backup.*)
    [[ ${#backups[@]} == 2 ]] || fail 'retirement backup overwritten on retry'
    jq '.nodes[1].type="unknown-engine"' "$ROOT/migration-old-state" > "$XM_STATE"
    cp "$XM_STATE" "$ROOT/migration-unknown"
    if xm_install; then fail 'unknown type silently retired'; fi
    cmp "$XM_STATE" "$ROOT/migration-unknown" || fail 'unknown type mutated'
    [[ ! -e $ROOT/migration-code ]] || fail 'unknown type updated code'
    xm_work_end; xm_unlock
) || fail 'retirement migration regression block failed'
pass 'retirement validates supported nodes, preserves private original backup, rolls back health failure and refuses unknown type'

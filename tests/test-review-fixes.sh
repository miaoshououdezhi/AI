#!/usr/bin/env bash
# Regression failures found by the independent read-only review. All service,
# install and package side effects are fixtures; file safety uses real files.
set -u
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then exit 77; fi
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
export XM_ROOT="$scratch/root"
source "$repo/xray-manager.sh"
trap 'xm_temp_cleanup; xm_work_end; rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
reject() { if "$@" > "$scratch/stdout" 2> "$scratch/stderr"; then fail "unexpected success: $*"; fi; }
prepare() {
    mkdir -p "$XM_HOME/bin" "$XM_ETC" "$XM_DATA" "$XM_LOG"
    local directory
    for directory in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG"; do printf 'xray-manager:1\n' > "$directory/.xray-manager-owned"; done
}
prepare
xm_need_commands() { return 0; }
xm_lock() { return 0; }
platform_detect() { XM_OS=debian; XM_OS_VERSION=12; XM_ARCH=amd64; XM_INIT=systemd; }
platform_detect

# Existing special files never receive configuration bytes. No FIFO reader is
# used: rejection must complete without blocking even when no reader exists.
(
    xm_ready() { return 0; }
    printf '{"schema_version":1,"core_version":"v26.3.27","nodes":[],"synthetic_secret":"fixture-only"}\n' > "$XM_STATE"
    xm_backup "$scratch/export.json" || fail 'normal export'
    cmp "$XM_STATE" "$scratch/export.json" || fail 'export lost bytes'
    "${XM_PYTHON:-python3}" - "$scratch/export.json" <<'PY'
import pathlib,stat,sys
p=pathlib.Path(sys.argv[1]);s=p.stat()
assert stat.S_ISREG(s.st_mode) and stat.S_IMODE(s.st_mode)==0o600
PY
    reject xm_backup "$scratch/export.json"
    cmp "$XM_STATE" "$scratch/export.json" || fail 'existing backup overwritten'
    mkfifo "$scratch/fifo"
    chmod 0644 "$scratch/fifo"
    reject xm_backup "$scratch/fifo"
    [[ -p $scratch/fifo ]] || fail 'FIFO replaced'
    mkdir "$scratch/directory"
    reject xm_backup "$scratch/directory"
    ln -s "$scratch/export.json" "$scratch/link"
    reject xm_backup "$scratch/link"
    ln -s "$scratch/directory" "$scratch/ancestor"
    reject xm_backup "$scratch/ancestor/output.json"
    [[ ! -e $scratch/directory/output.json ]] || fail 'ancestor symlink crossed'
    # Exercise the copy helper directly as well, beyond the shell path guard.
    reject xm_export_snapshot "$XM_STATE" "$scratch/ancestor/direct.json"
    [[ ! -e $scratch/directory/direct.json ]] || fail 'copy helper crossed ancestor'
    "${XM_PYTHON:-python3}" - "$scratch/oversize.json" <<'PY'
import sys
with open(sys.argv[1],'wb') as f:f.truncate(16777217)
PY
    reject xm_export_snapshot "$scratch/oversize.json" "$scratch/partial.json"
    [[ ! -e $scratch/partial.json ]] || fail 'partial export retained'
    reject xm_export_snapshot "$scratch/fifo" "$scratch/from-fifo.json"
    [[ ! -e $scratch/from-fifo.json ]] || fail 'nonregular source created backup'
) || fail 'export safety fixture'
pass 'export regular 0600 fidelity; existing file/FIFO/directory/link rejection; bounded read cleanup'

# Mutate then fail once on the second core, mirroring partial init failure.
(
    xm_ready() { return 0; }
    protocol_has_extra() { return 0; }
    printf '#!/bin/sh\n' > "$XM_EXTRA_BIN"; chmod 0700 "$XM_EXTRA_BIN"
    MAIN_ENABLED=0; EXTRA_ENABLED=0; EXTRA_FAIL=0; RESTORE_FAIL=0; QUERY_FAIL=0
    platform_service_enabled() {
        [[ $QUERY_FAIL == 0 ]] || return 2
        if [[ $1 == main ]]; then [[ $MAIN_ENABLED == 1 ]]; else [[ $EXTRA_ENABLED == 1 ]]; fi
    }
    xm_service_call() {
        case $1 in
            status) return 1 ;;
            enable) MAIN_ENABLED=1 ;;
            disable) [[ $RESTORE_FAIL == 0 ]] || return 1; MAIN_ENABLED=0 ;;
            *) fail 'unexpected main action' ;;
        esac
    }
    xm_extra_service_call() {
        case $1 in
            status) return 1 ;;
            enable|disable)
                if [[ $EXTRA_FAIL == 1 ]]; then EXTRA_FAIL=0; return 1; fi
                [[ $1 != enable ]] || EXTRA_ENABLED=1
                [[ $1 != disable ]] || EXTRA_ENABLED=0 ;;
            *) fail 'unexpected auxiliary action' ;;
        esac
    }
    for action in enable disable; do
        if [[ $action == enable ]]; then MAIN_ENABLED=0; EXTRA_ENABLED=0; else MAIN_ENABLED=1; EXTRA_ENABLED=1; fi
        original=$MAIN_ENABLED; EXTRA_FAIL=1
        reject xm_service "$action"
        [[ $MAIN_ENABLED == "$original" && $EXTRA_ENABLED == "$original" ]] || fail 'partial boot operation not restored'
    done
    MAIN_ENABLED=0; EXTRA_ENABLED=1; EXTRA_FAIL=1
    reject xm_service enable
    [[ $MAIN_ENABLED == 0 && $EXTRA_ENABLED == 1 ]] || fail 'independent prior boot flags lost'
    QUERY_FAIL=1
    reject xm_service enable
    [[ $MAIN_ENABLED == 0 && $EXTRA_ENABLED == 1 ]] || fail 'query failure changed boot flags'
    QUERY_FAIL=0; EXTRA_ENABLED=0; EXTRA_FAIL=1; RESTORE_FAIL=1
    reject xm_service enable
    grep -q '开机启动状态恢复未完成' "$scratch/stderr" || fail 'failed restore hidden'
) || fail 'boot state fixture'
rm -f "$XM_EXTRA_BIN"
pass 'enable/disable rollback restores independent flags; unknown query refuses; failed restore visible'

# Scheduled worker: late/disabled and query failure cannot even validate or
# restart a service. Manual restart continues to work outside scheduled time.
(
    xm_ready() { return 0; }
    DUE_STATUS=1; VALIDATED=0; RESTARTED=0
    platform_restart_schedule_due() { return "$DUE_STATUS"; }
    xm_service_validate() { VALIDATED=$((VALIDATED+1)); }
    xm_service_call() { case $1 in status) return 0 ;; restart) RESTARTED=$((RESTARTED+1)) ;; *) return 0 ;; esac; }
    platform_health() { return 0; }
    xm_scheduled_restart || fail 'missed minute should skip successfully'
    [[ $VALIDATED == 0 && $RESTARTED == 0 ]] || fail 'late worker touched service'
    DUE_STATUS=2; reject xm_scheduled_restart
    [[ $VALIDATED == 0 && $RESTARTED == 0 ]] || fail 'failed due query touched service'
    DUE_STATUS=0; xm_scheduled_restart || fail 'due worker rejected'
    [[ $VALIDATED == 1 && $RESTARTED == 1 ]] || fail 'due worker did not restart'
    DUE_STATUS=1; xm_service restart || fail 'manual restart blocked by schedule'
    [[ $RESTARTED == 2 ]] || fail 'manual restart not executed'
) || fail 'worker due fixture'
pass 'scheduled worker gates late/disabled/error before services; manual restart unaffected'

# Log selection works without requiring a healthy node state, and the menu
# uses the same fixed source vocabulary as CLI. No real journalctl is invoked.
(
    platform_logs() { printf '%s %s\n' "$1" "$2" >> "$scratch/log-calls"; }
    xm_ready() { fail 'logs should not depend on node validation'; }
    xm_logs || fail 'default logs'
    xm_logs 25 || fail 'legacy lines'
    for source in main extra update restart; do xm_logs "$source" 9 || fail 'explicit source'; done
    printf '80 main\n25 main\n9 main\n9 extra\n9 update\n9 restart\n' > "$scratch/expected-logs"
    cmp "$scratch/log-calls" "$scratch/expected-logs" || fail 'log source/line routing'
    for bad in zero invalid 0 1001; do reject xm_logs "$bad"; done
    reject xm_logs 25 extra
    rm "$scratch/log-calls"
    printf '1\n' | xm_menu_logs || fail 'log menu main'
    printf '2\n' | xm_menu_logs || fail 'log menu extra'
    printf '3\n' | xm_menu_logs || fail 'log menu update'
    printf '4\n' | xm_menu_logs || fail 'log menu restart'
    printf '80 main\n80 extra\n80 update\n80 restart\n' > "$scratch/expected-logs"
    cmp "$scratch/log-calls" "$scratch/expected-logs" || fail 'log menu source mismatch'
) || fail 'log CLI/menu fixture'
pass 'logs legacy CLI and four menu/CLI sources without node-validation dependency'

# A stopped/broken main core must not hide the auxiliary core diagnostic.
(
    xm_installed() { return 0; }
    state_validate() { return 0; }
    protocol_has_extra() { return 0; }
    protocol_generate() { return 1; }
    protocol_generate_extra() { printf '{}\n' > "$2"; }
    state_extra_native_validate() { return 0; }
    xm_service_call() { return 1; }
    xm_extra_service_call() { return 0; }
    platform_extra_health() { printf 'extra checked\n' >> "$scratch/diag-calls"; return 0; }
    printf '{}\n' > "$XM_EXTRA_CONFIG"
    reject xm_diagnose
    grep -q 'extra checked' "$scratch/diag-calls" || fail 'main failure hid auxiliary health'
    grep -q '辅助核心服务健康' "$scratch/stderr" || fail 'auxiliary result missing'
    xm_work_end
) || fail 'diagnostic aggregation fixture'
rm -f "$XM_EXTRA_CONFIG"
pass 'diagnostics continue auxiliary checks after main config/service failures'

# Actual first-install failure leaves no core/state, then actual uninstall must
# reach the unchanged real file/ownership allowlist and remove only owned files.
rm -f "$XM_STATE" "$XM_CONFIG" "$XM_BIN"
(
    platform_shortcut_preflight() { return 0; }
    platform_dependencies_snapshot() { return 0; }
    platform_dependencies() { return 0; }
    platform_prepare() { return 0; }
    platform_fetch_core() { printf '#!/bin/sh\nexit 0\n' > "$2"; chmod 0700 "$2"; }
    xm_install_code() { printf 'fixture manager\n' > "$XM_HOME/xray-manager.sh"; }
    state_apply() { cp "$1" "$XM_STATE"; cp "$2" "$XM_BIN"; printf '{}\n' > "$XM_CONFIG"; }
    platform_install_service() { return 0; }
    platform_remove_service() { return 0; }
    platform_health() { return 1; }
    xm_service_call() { printf '%s\n' "$1" >> "$scratch/install-service-calls"; return 0; }
    platform_restart_schedule() { return 0; }
    platform_system_update_schedule() { return 0; }
    platform_shortcut_remove() { return 0; }
    reject xm_install
    [[ -f $XM_HOME/xray-manager.sh && ! -e $XM_STATE && ! -e $XM_BIN ]] || fail 'unexpected failed install fixture'
    xm_work_end
    printf 'foreign\n' > "$XM_HOME/foreign.txt"
    XM_YES=1; reject xm_uninstall
    [[ -f $XM_HOME/foreign.txt && -f $XM_HOME/xray-manager.sh ]] || fail 'foreign file cleanup boundary crossed'
    rm "$XM_HOME/foreign.txt"
    xm_uninstall || fail 'owned incomplete install cleanup'
    [[ ! -e $XM_HOME && ! -e $XM_ETC && ! -e $XM_DATA && ! -e $XM_LOG ]] || fail 'incomplete cleanup retained owned directories'
    [[ -f $scratch/export.json ]] || fail 'external export deleted'
) || fail 'incomplete installation cleanup fixture'
pass 'failed first install can uninstall through real allowlist; unknown files and external export retained'

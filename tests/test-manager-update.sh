#!/usr/bin/env bash
# Real updater and fixed-URL parsing; remote transport/installer are fixtures.
set -u
if (( BASH_VERSINFO[0]<4 || (BASH_VERSINFO[0]==4 && BASH_VERSINFO[1]<4) )); then exit 77; fi
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
scratch=$(mktemp -d)
export XM_ROOT="$scratch/root"
source "$repo/xray-manager.sh"
trap 'state_exit_cleanup $?; rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$XM_HOME/lib" "$XM_HOME/assets" "$XM_HOME/bin" "$XM_ETC" "$XM_LOG"
for directory in "$XM_HOME" "$XM_ETC" "$XM_LOG"; do printf 'xray-manager:1\n' > "$directory/.xray-manager-owned"; done
printf 'old-manager\n' > "$XM_HOME/xray-manager.sh"
printf 'old-common\n' > "$XM_HOME/lib/common.sh"
printf 'unchanged-core\n' > "$XM_BIN"
printf '{"schema_version":1,"core_version":"v26.3.27","nodes":[{"id":"existing","name":"populated fixture","port":2443}]}\n' > "$XM_STATE"
cp "$XM_STATE" "$scratch/original-state"; cp "$XM_BIN" "$scratch/original-core"
xm_ready() { xm_lock; }
# Model trusted root-owned installed code while keeping CI fixtures user-owned.
# All permission checks use real stat; only the ownership result is isolated.
stat() { if [[ ${1:-} == -c && ${2:-} == %u ]]; then printf '0\n'; else command stat "$@"; fi; }
TEST_MODE=success; TEST_CONFIRM=1; TEST_SIGNAL=TERM
xm_confirm() { [[ -z $XM_LOCK_FD ]] || fail 'confirmation holds lock'; [[ $TEST_CONFIRM == 1 ]]; }
TEST_MAIN_SHA=1111111111111111111111111111111111111111
TEST_RUNTIME_SHA=2222222222222222222222222222222222222222
xm_manager_fetch() {
    printf '%s\n' "$1" >> "$scratch/urls"
    case $1 in
        https://api.github.com/repos/miaoshououdezhi/AI/git/ref/heads/main)
            if [[ $TEST_MODE == malformed ]]; then printf '{"ref":"refs/heads/other","object":{"type":"commit","sha":"%s"}}\n' "$TEST_MAIN_SHA" > "$2"
            elif [[ $TEST_MODE == network ]]; then return 1
            else printf '{"ref":"refs/heads/main","object":{"type":"commit","sha":"%s"}}\n' "$TEST_MAIN_SHA" > "$2"; fi ;;
        "https://raw.githubusercontent.com/miaoshououdezhi/AI/$TEST_MAIN_SHA/deploy.sh")
            if [[ $TEST_MODE == badpin ]]; then printf '#!/bin/sh\n# no fixed runtime\n' > "$2"; return 0; fi
            cat > "$2" <<SCRIPT
#!/bin/sh
# Official fixed runtime URL (not executed by this fixture).
: <<'RUNTIME'
https://github.com/miaoshououdezhi/AI/archive/$TEST_RUNTIME_SHA.tar.gz
RUNTIME
printf 'executed\\n' >> '$scratch/executed'
printf 'new-manager\\n' > '$XM_HOME/xray-manager.sh'
printf 'new-common\\n' > '$XM_HOME/lib/common.sh'
SCRIPT
            [[ $TEST_MODE != failure ]] || printf 'exit 1\n' >> "$2"
            [[ $TEST_MODE != interrupted ]] || printf 'kill -%s "$PPID"\n' "$TEST_SIGNAL" >> "$2" ;;
        *) fail 'updater fetched unexpected URL' ;;
    esac
}
# Sandbox mode must reject before any query or deployment execution.
if xm_dispatch update-manager >/dev/null 2>&1; then fail 'sandbox updater accepted'; fi
[[ ! -e $scratch/urls && ! -e $scratch/executed ]] || fail 'sandbox updater caused network/execution'
# Paths stay private. The installer is a fixed local fixture below, never a real
# bootstrap; empty XM_ROOT allows testing production-only validation branches.
export XM_ROOT=
reject_update() {
    rm -f "$scratch/executed"
    if xm_dispatch update-manager > "$scratch/stdout" 2> "$scratch/error"; then fail 'invalid update accepted'; fi
    [[ ! -e $scratch/executed && $(cat "$XM_HOME/xray-manager.sh") == old-manager ]] || fail 'rejected update changed code'
    cmp "$XM_STATE" "$scratch/original-state" && cmp "$XM_BIN" "$scratch/original-core" || fail 'rejected update changed nodes/core'
}
for TEST_MODE in malformed network badpin; do reject_update; done
TEST_MODE=success; TEST_CONFIRM=0; reject_update; TEST_CONFIRM=1
TEST_MODE=failure
if xm_dispatch update-manager > "$scratch/stdout" 2> "$scratch/error"; then fail 'failed installer accepted'; fi
[[ $(cat "$XM_HOME/xray-manager.sh") == old-manager && $(cat "$XM_HOME/lib/common.sh") == old-common ]] || fail 'failed installer did not restore prior manager code'
cmp "$XM_STATE" "$scratch/original-state" && cmp "$XM_BIN" "$scratch/original-core" || fail 'code rollback overwrote nodes/core'
grep -q '已恢复原管理代码' "$scratch/error" || fail 'rollback message absent'
TEST_MODE=interrupted
for TEST_SIGNAL in INT TERM HUP; do
if xm_dispatch update-manager > "$scratch/stdout" 2> "$scratch/interrupted"; then fail 'interrupted update returned success'; fi
backup_path=$(sed -n 's@.*备份保留于 \(.*\)/code，请.*@\1@p' "$scratch/interrupted")
[[ -n $backup_path && -f $backup_path/code/xray-manager.sh && $(stat -c %a "$backup_path") == 700 ]] || fail 'signal removed private recovery backup'
cp "$backup_path/code/xray-manager.sh" "$XM_HOME/xray-manager.sh"
cp "$backup_path/code/lib/common.sh" "$XM_HOME/lib/common.sh"
rm -rf -- "$backup_path"
done
TEST_MODE=success
xm_dispatch update-manager > "$scratch/stdout" 2> "$scratch/success" || fail 'manager update'
[[ ! -s $scratch/stdout && $(cat "$XM_HOME/xray-manager.sh") == new-manager ]] || fail 'manager update stream/result'
grep -q "$TEST_MAIN_SHA" "$scratch/success" && grep -q "$TEST_RUNTIME_SHA" "$scratch/success" || fail 'two SHA confirmation missing'
cmp "$XM_STATE" "$scratch/original-state" && cmp "$XM_BIN" "$scratch/original-core" || fail 'successful update changed core/nodes'
if xm_dispatch update-manager arbitrary >/dev/null 2>&1; then fail 'update accepted arguments'; fi
printf 'PASS fixed GitHub references/raw SHA, validation/cancel no side effects, failure restores code, populated state/core preserved\n'
# The transport enforces limits independently of Content-Length. Run its actual
# body with a local curl fixture; this is not a network or installer test.
(
    # shellcheck disable=SC1090
    source <(sed -n '/^xm_manager_fetch() (/,/^)/p' "$repo/xray-manager.sh")
    curl() { head -c 1048578 /dev/zero; }
    if xm_manager_fetch https://fixture "$scratch/oversize"; then fail 'oversize download accepted'; fi
    [[ $(wc -c < "$scratch/oversize") -le 1048577 ]] || fail 'response bound not enforced'
) || fail 'bounded download fixture'
printf 'PASS bounded download rejects oversized streaming response\n'

#!/usr/bin/env bash
# Direct repeat-install rollback, with private filesystem/service fixtures.
set -euo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)
export XM_ROOT=$scratch/root
source "$repo/xray-manager.sh"
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# Reuse the real atomic-copy implementation, then inject only selected writes.
# shellcheck disable=SC1090
source <(declare -f xm_atomic_copy | sed '1s/^xm_atomic_copy ()/real_atomic_copy ()/')
xm_atomic_copy() {
    if [[ $MODE == copy && $2 == "$XM_HOME/install.sh" ]]; then return 1; fi
    real_atomic_copy "$@"
}
xm_require_root() { return 0; }
platform_detect() { XM_INIT=systemd; }
platform_shortcut_preflight() { return 0; }
platform_dependencies_snapshot() { return 0; }
platform_dependencies() { return 0; }
platform_prepare() { return 0; }
xm_lock() { return 0; }
xm_installed() { return 0; }
xm_retire_trojan() { return 0; }
platform_extra_ensure() { return 0; }
platform_extra_preflight() { return 0; }
platform_install_service() {
    real_atomic_copy "$_XM_PLATFORM_ASSETS/xray-manager.service" "$XM_ROOT/etc/systemd/system/xray-manager.service" 0755 || return 1
    if [[ $MODE == main-service ]]; then return 1; fi
    if [[ $MODE == INT || $MODE == TERM || $MODE == HUP ]]; then kill -s "$MODE" "$BASHPID"; return 0; fi
    real_atomic_copy "$_XM_PLATFORM_ASSETS/xray-manager.logrotate" "$XM_ROOT/etc/logrotate.d/xray-manager" 0644
}
platform_extra_install_service() {
    real_atomic_copy "$_XM_PLATFORM_ASSETS/xray-manager-extra.service" "$XM_ROOT/etc/systemd/system/xray-manager-extra.service" 0755 || return 1
    [[ $MODE != extra-service ]]
}
platform_shortcut_install() {
    real_atomic_copy "$_XM_PLATFORM_ASSETS/xy" "$XM_ROOT/usr/local/bin/xy" 0755 || return 1
    [[ $MODE != shortcut ]]
}
reset_fixture() {
    rm -rf -- "$XM_ROOT"
    mkdir -p "$XM_HOME/bin" "$XM_HOME/lib" "$XM_HOME/assets" "$XM_ETC" "$XM_DATA" "$XM_LOG" "$XM_ROOT/etc/systemd/system" "$XM_ROOT/etc/logrotate.d" "$XM_ROOT/usr/local/bin"
    printf '# old manager\n' > "$XM_HOME/xray-manager.sh"
    printf '# old common\n' > "$XM_HOME/lib/common.sh"
    printf '# old entry\n' > "$XM_HOME/install.sh"
    chmod 0640 "$XM_HOME/lib/common.sh"
    chmod 0700 "$XM_HOME/lib" "$XM_HOME/assets"
    printf 'main core unchanged\n' > "$XM_BIN"
    printf 'extra core unchanged\n' > "$XM_EXTRA_BIN"
    chmod 0755 "$XM_BIN" "$XM_EXTRA_BIN"
    printf '{"core_version":"v26.10.31","nodes":[],"schema_version":1}\n' > "$XM_STATE"
    printf 'active config unchanged\n' > "$XM_CONFIG"
    printf '# xray-manager-owned:1\nold main service\n' > "$XM_ROOT/etc/systemd/system/xray-manager.service"
    printf '# xray-manager-owned:1\nold extra service\n' > "$XM_ROOT/etc/systemd/system/xray-manager-extra.service"
    printf '# xray-manager-owned:1\nold logrotate\n' > "$XM_ROOT/etc/logrotate.d/xray-manager"
    # xy is deliberately absent: a later failure must remove its new file.
    python3 - "$XM_ROOT" "$scratch/before.json" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);out={}
for f in p.rglob('*'):
 if f.is_file():out[str(f.relative_to(p))]=[hashlib.sha256(f.read_bytes()).hexdigest(),f.stat().st_mode & 0o777]
pathlib.Path(sys.argv[2]).write_text(json.dumps(out,sort_keys=True))
PY
}
check_restored() {
    python3 - "$XM_ROOT" "$scratch/before.json" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);out={}
for f in p.rglob('*'):
 if f.is_file():out[str(f.relative_to(p))]=[hashlib.sha256(f.read_bytes()).hexdigest(),f.stat().st_mode & 0o777]
assert out==json.loads(pathlib.Path(sys.argv[2]).read_text()),'installed bytes/modes changed after failed repeat install'
assert (p/'opt/xray-manager/lib').stat().st_mode & 0o777==0o700
assert (p/'opt/xray-manager/assets').stat().st_mode & 0o777==0o700
assert not list((p/'etc/xray-manager').glob('.install-code.*')),'successful recovery left transaction debris'
PY
}
for MODE in copy main-service extra-service shortcut INT TERM HUP; do
    reset_fixture
    result=0
    xm_install > "$scratch/out" 2> "$scratch/err" || result=$?
    [[ $result != 0 ]] || fail "failure accepted: $MODE"
    case $MODE:$result in INT:130|TERM:143|HUP:129) ;; INT:*|TERM:*|HUP:*) fail "signal status lost: $MODE/$result" ;; esac
    check_restored || fail "rollback did not restore: $MODE"
done
MODE=success; reset_fixture
xm_install > "$scratch/out" 2> "$scratch/err" || fail 'successful refresh'
cmp "$repo/xray-manager.sh" "$XM_HOME/xray-manager.sh" || fail 'new manager absent'
cmp "$repo/lib/common.sh" "$XM_HOME/lib/common.sh" || fail 'new common absent'
cmp "$repo/assets/xray-manager.service" "$XM_ROOT/etc/systemd/system/xray-manager.service" || fail 'new service absent'
[[ $(cat "$XM_BIN") == 'main core unchanged' && $(cat "$XM_EXTRA_BIN") == 'extra core unchanged' && $(cat "$XM_CONFIG") == 'active config unchanged' ]] || fail 'code update changed runtime data'
# Reject a missing source before writing any installed file.
MODE=success; reset_fixture
mkdir -p "$scratch/incomplete"
cp "$repo/xray-manager.sh" "$scratch/incomplete/"
if (XM_CODE_ROOT=$scratch/incomplete; xm_install); then fail 'partial source accepted'; fi
check_restored || fail 'source preflight changed installation'
# Existing shortcut symlinks were already forbidden by platform preflight;
# the transaction also refuses one before changing installed code.
MODE=success; reset_fixture
ln -s "$XM_HOME/xray-manager.sh" "$XM_ROOT/usr/local/bin/xy"
if xm_install > "$scratch/out" 2> "$scratch/err"; then fail 'shortcut symlink accepted'; fi
[[ -L $XM_ROOT/usr/local/bin/xy && $(cat "$XM_HOME/xray-manager.sh") == '# old manager' ]] || fail 'symlink refusal changed code'
# A recovery write failure must retain a private, usable old-code snapshot.
MODE=main-service; reset_fixture
mv() {
    if [[ ${1:-} == -f && ${2:-} == -- && ${3:-} == *'.xray-manager-restore.'* ]]; then return 1; fi
    command mv "$@"
}
if xm_install > "$scratch/out" 2> "$scratch/err"; then fail 'failed rollback accepted'; fi
python3 - "$XM_ETC" <<'PY'
import pathlib,sys
roots=list(pathlib.Path(sys.argv[1]).glob('.install-code.*'))
assert len(roots)==1 and roots[0].stat().st_mode & 0o777==0o700
assert (roots[0]/'old/0').read_text()=='# old manager\n'
PY
unset -f mv
printf 'PASS: repeat-install complete staging, copy/service/shortcut/signal rollback, modes/data preservation and private failed-recovery evidence\n'

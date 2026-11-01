#!/usr/bin/env bash
# Real upgrade transactions and file copies; network/init adapters are fixtures.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d)
fixture=$(cd "$fixture" && pwd -P)
trap 'rm -rf -- "$fixture"' EXIT
export XM_ROOT=$fixture/root
source "$repo/lib/common.sh"
source "$repo/lib/platform.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if "$@" > "$fixture/out" 2> "$fixture/err"; then fail "unexpected success: $*"; fi; }
# Verify native init status mapping without calling an actual service manager.
TEST_STATUS=0; TEST_STATE=active
systemctl() { [[ $1 == is-active && $2 == xray-manager-extra.service ]] || return 99; printf '%s\n' "$TEST_STATE"; return "$TEST_STATUS"; }
rc-service() { [[ $1 == xray-manager-extra && $2 == status ]] || return 99; return "$TEST_STATUS"; }
status_is() {
    local want=$1 result=0
    _platform_service_running xray-manager-extra || result=$?
    [[ $result == "$want" ]] || fail "status: expected $want got $result"
}
XM_INIT=systemd
for row in active:0:0 inactive:3:1 failed:3:1 unknown:4:2 activating:0:2 deactivating:3:2 active:1:2; do
    TEST_STATE=${row%%:*}; rest=${row#*:}; TEST_STATUS=${rest%%:*}; status_is "${rest##*:}"
done
XM_INIT=openrc
for row in 0:0 3:1 1:2 4:2 8:2 16:2 32:2; do TEST_STATUS=${row%:*}; status_is "${row#*:}"; done
# Adapter failures/missing owned service definitions are unknown, not stopped.
(
    _platform_init_available() { return 1; }
    result=0; platform_service status >/dev/null 2>&1 || result=$?
    [[ $result == 2 ]] || fail 'main init failure became stopped'
    platform_extra_preflight() { return 1; }
    result=0; platform_extra_service status >/dev/null 2>&1 || result=$?
    [[ $result == 2 ]] || fail 'extra preflight failure became stopped'
    _platform_init_available() { return 0; }
    _platform_owned_file() { return 1; }
    result=0; platform_service status >/dev/null 2>&1 || result=$?
    [[ $result == 2 ]] || fail 'unowned main service became stopped'
)
unset -f systemctl rc-service
printf 'PASS: systemd/OpenRC running, stopped and unknown states remain distinct\n'

mkdir -p "$XM_HOME/bin" "$XM_ETC" "$XM_DATA" "$XM_LOG"
for directory in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG"; do printf 'xray-manager:1\n' > "$directory/.xray-manager-owned"; done
# Keep all operations inside the private fixture filesystem.
_platform_real() { return 0; }
platform_extra_preflight() { [[ $TEST_MODE != preflight ]] || return 1; }
export XM_ARCH=amd64 XM_LIBC=glibc TEST_MODE=success
hash_file() { python3 - "$1" <<'PY'
import hashlib,pathlib,sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}
make_core() {
    local destination=$1 version=$2
    cat > "$destination" <<CORE
#!/bin/sh
case \$1 in
version) printf 'sing-box version $version\\n';;
check) [ '$version' != 1.14.4 ] || [ "\${TEST_MODE:-}" != nativefail ]; local_status=\$?; exit "\$local_status";;
*) exit 1;;
esac
CORE
    chmod 0755 "$destination"
}
make_core "$fixture/new-core" 1.14.4
curl() {
    local output='' last='' arg
    while (($#)); do arg=$1; shift; if [[ $arg == --output ]]; then output=$1; shift; fi; last=$arg; done
    [[ $last == https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-amd64-glibc.tar.gz ]] || fail 'download not pinned to official 1.14.4 asset'
    [[ $TEST_MODE != downloadfail ]] || return 1
    printf 'archive-fixture\n' > "$output"
    printf 'download\n' >> "$fixture/downloads"
}
_platform_extra_verify_archive() {
    [[ $2 == 231e57c18378f780a08de832844a1ca9716e17a7bcf82964b350844d243c03ac && $3 == sing-box-1.14.4-linux-amd64-glibc && $4 == amd64 ]] || fail 'download digest/architecture mismatch'
    [[ $TEST_MODE != archivefail ]] || return 1
    cp "$fixture/new-core" "$5"
    [[ $TEST_MODE != wrongversion ]] || make_core "$5" 1.14.2
    hash_file "$5" > "$6"
}
platform_extra_service() {
    local version
    case $1 in
        status) [[ $TEST_MODE != unknown ]] || return 2; [[ $(cat "$fixture/running") == 1 ]];;
        stop)
            printf 'stop\n' >> "$fixture/actions"
            if [[ $TEST_MODE == stopfail && ! -e $fixture/stop-failed ]]; then touch "$fixture/stop-failed"; return 1; fi
            printf '0\n' > "$fixture/running";;
        start)
            printf 'start\n' >> "$fixture/actions"
            version=$("$XM_EXTRA_BIN" version)
            [[ $TEST_MODE != startfail || $version != 'sing-box version 1.14.4' ]] || return 1
            printf '1\n' > "$fixture/running";;
        *) fail 'upgrade changed unsupported service state';;
    esac
}
platform_extra_health() {
    [[ $(cat "$fixture/running") == 1 ]] || return 1
    [[ $TEST_MODE != healthfail || $("$XM_EXTRA_BIN" version) != 'sing-box version 1.14.4' ]]
}
# Inject faults after a real atomic binary replacement, or before hash promotion.
eval "$(declare -f xm_atomic_copy | sed '1s/xm_atomic_copy/_test_atomic_copy/')"
xm_atomic_copy() {
    if [[ $TEST_MODE == hashfail && $1 == */hash ]]; then return 1; fi
    if [[ $TEST_MODE == restorefail && $1 == */old-core ]]; then return 1; fi
    _test_atomic_copy "$@" || return 1
    if [[ $1 == */core && $2 == "$XM_EXTRA_BIN" ]]; then
        case $TEST_MODE in
            signal-INT|signal-TERM|signal-HUP)
                python3 - "${TEST_MODE#signal-}" <<'PY'
import os,signal,sys
os.kill(os.getppid(),getattr(signal,'SIG'+sys.argv[1]))
PY
                ;;
            restorefail) return 1 ;;
        esac
    fi
}
reset_fixture() {
    TEST_MODE=success
    make_core "$XM_EXTRA_BIN" 1.14.2
    hash_file "$XM_EXTRA_BIN" > "$XM_ETC/extra-core.sha256"
    chmod 0600 "$XM_ETC/extra-core.sha256"
    printf '{}\n' > "$XM_EXTRA_CONFIG"
    printf '1\n' > "$fixture/running"
    printf 'unchanged-main\n' > "$XM_BIN"
    printf 'unchanged-state\n' > "$XM_STATE"
    : > "$fixture/actions"; : > "$fixture/downloads"
    rm -f "$fixture/stop-failed"
    cp "$XM_EXTRA_BIN" "$fixture/before-core"; cp "$XM_ETC/extra-core.sha256" "$fixture/before-hash"
}
unchanged() {
    cmp "$XM_EXTRA_BIN" "$fixture/before-core" && cmp "$XM_ETC/extra-core.sha256" "$fixture/before-hash" || fail 'old binary/hash changed'
    [[ $(cat "$XM_BIN") == unchanged-main && $(cat "$XM_STATE") == unchanged-state ]] || fail 'main core or nodes changed'
}
cleaned() {
    local item
    for item in "$XM_ETC"/.extra-upgrade.* "$XM_ETC"/.extra-download.*; do [[ ! -e $item ]] || fail 'private temporary directory leaked'; done
}
reset_fixture
platform_extra_ensure > "$fixture/out" 2> "$fixture/err"
grep -q 'xy upgrade-extra' "$fixture/err" || fail 'legacy upgrade guidance absent'
unchanged; [[ ! -s $fixture/downloads && ! -s $fixture/actions ]] || fail 'ensure silently upgraded existing core'
# Fresh installation uses the new core and its integrity record.
rm "$XM_EXTRA_BIN" "$XM_ETC/extra-core.sha256"
platform_extra_ensure
[[ $("$XM_EXTRA_BIN" version) == 'sing-box version 1.14.4' ]] || fail 'fresh install not current'
[[ $(hash_file "$XM_EXTRA_BIN") == "$(cat "$XM_ETC/extra-core.sha256")" ]] || fail 'fresh install hash'
cleaned
reset_fixture
platform_extra_upgrade
[[ $("$XM_EXTRA_BIN" version) == 'sing-box version 1.14.4' && $(cat "$fixture/running") == 1 ]] || fail 'upgrade result/running state'
[[ $(hash_file "$XM_EXTRA_BIN") == "$(cat "$XM_ETC/extra-core.sha256")" ]] || fail 'upgraded digest'
[[ $(cat "$fixture/actions") == $'stop\nstart' ]] || fail 'unexpected service actions'
: > "$fixture/actions"; : > "$fixture/downloads"
platform_extra_upgrade
[[ ! -s $fixture/actions && ! -s $fixture/downloads ]] || fail 'current version not idempotent'
cleaned
reset_fixture; printf '0\n' > "$fixture/running"
platform_extra_upgrade
[[ $(cat "$fixture/running") == 0 && ! -s $fixture/actions ]] || fail 'stopped service was started'
cleaned
for TEST_CASE in downloadfail archivefail wrongversion nativefail unknown preflight stopfail hashfail startfail healthfail signal-INT signal-TERM signal-HUP; do
    reset_fixture; TEST_MODE=$TEST_CASE
    reject platform_extra_upgrade
    unchanged
    [[ $(cat "$fixture/running") == 1 ]] || fail "running state lost: $TEST_CASE"
    cleaned
    printf 'PASS: auxiliary upgrade failure recovery %s\n' "$TEST_CASE"
done
reset_fixture; TEST_MODE=restorefail
reject platform_extra_upgrade
found=0
for recovery in "$XM_ETC"/.extra-upgrade.*; do
    [[ -d $recovery ]] || continue
    [[ -f $recovery/old-core && -f $recovery/old-hash ]] || fail 'rollback failure discarded recovery data'
    grep -Fq "$recovery" "$fixture/err" || fail 'rollback failure omitted recovery directory'
    found=1; rm -rf -- "$recovery"
done
[[ $found == 1 ]] || fail 'rollback failure did not preserve private recovery data'
reset_fixture; printf 'corrupt\n' > "$XM_ETC/extra-core.sha256"
reject platform_extra_upgrade
[[ ! -s $fixture/downloads && ! -s $fixture/actions ]] || fail 'invalid existing digest reached mutation'
reset_fixture; mv "$XM_EXTRA_CONFIG" "$fixture/foreign-config"; ln -s "$fixture/foreign-config" "$XM_EXTRA_CONFIG"
reject platform_extra_upgrade
[[ ! -s $fixture/downloads && ! -s $fixture/actions ]] || fail 'symlink config reached mutation'
rm "$XM_EXTRA_CONFIG"
reset_fixture; rm "$XM_EXTRA_BIN" "$XM_ETC/extra-core.sha256"
reject platform_extra_upgrade
[[ ! -e $XM_EXTRA_BIN && ! -s $fixture/downloads && ! -s $fixture/actions ]] || fail 'upgrade installed an absent core'
reject platform_extra_upgrade unexpected
printf 'PASS: auxiliary install/legacy compatibility, staged upgrade, idempotence, stopped state, invalid hash, missing core and preserved recovery evidence\n'

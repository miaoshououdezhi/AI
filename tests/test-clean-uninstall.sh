#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/lib/platform.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/xray-clean-tests.XXXXXXXX")
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if "$@" >"$tmp/out" 2>"$tmp/err"; then fail "unexpected success: $*"; fi; }
export XM_ROOT=$tmp/root
platform_prepare
mkdir -p "$XM_HOME/assets" "$XM_HOME/lib"
cp "$repo/assets/xy" "$XM_HOME/assets/xy"
for name in xray-manager-system-update.service xray-manager-system-update.timer xray-manager-system-update.openrc xray-manager-system-update.py; do
    cp "$repo/assets/$name" "$XM_HOME/assets/$name"
done
printf '# xray-manager-owned:1\nweekly\n04:00\n' > "$XM_ETC/system-update-schedule"
printf 'core\n' > "$XM_BIN"
printf '{"nodes":[]}\n' > "$XM_ETC/state.json"
printf 'log\n' > "$XM_LOG/console.log"
printf 'native failure\n' > "$XM_LOG/last-error.log"
printf 'native extra failure\n' > "$XM_LOG/last-extra-error.log"
printf 'scheduled update output\n' > "$XM_LOG/system-update-schedule.log"
printf 'rotated output\n' > "$XM_LOG/system-update-schedule.log.1.gz"
printf 'external export\n' > "$tmp/export.json"
platform_shortcut_install
platform_clean_uninstall_preflight
# Failed first-install cleanup has no core/state, but still needs all original
# ownership and unknown-leaf protections. This never touches host services.
mv "$XM_BIN" "$tmp/core-before"
mv "$XM_ETC/state.json" "$tmp/state-before"
platform_clean_uninstall_preflight
printf 'unknown incomplete-install leaf\n' > "$XM_ETC/foreign.conf"
reject platform_clean_uninstall_preflight
[[ -f $XM_ETC/foreign.conf ]] || fail 'incomplete cleanup changed unknown leaf'
rm "$XM_ETC/foreign.conf"
mv "$XM_DATA/.xray-manager-owned" "$tmp/owner-before"
reject platform_clean_uninstall_preflight
mv "$tmp/owner-before" "$XM_DATA/.xray-manager-owned"
ln -s "$tmp/export.json" "$XM_ETC/state.json"
reject platform_clean_uninstall_preflight
rm "$XM_ETC/state.json"
mv "$tmp/core-before" "$XM_BIN"
mv "$tmp/state-before" "$XM_ETC/state.json"
printf 'PASS: incomplete-install preflight retains ownership, unknown-leaf and symlink gates\n'
printf 'foreign preserved\n' > "$XM_ETC/foreign.conf"
reject platform_clean_uninstall_preflight
[[ $(cat "$XM_ETC/foreign.conf") == 'foreign preserved' && -f $XM_BIN ]] || fail 'foreign preflight mutation'
rm "$XM_ETC/foreign.conf"
ln -s "$tmp/export.json" "$XM_LOG/console.log.1"
reject platform_clean_uninstall_preflight
[[ $(cat "$tmp/export.json") == 'external export' ]] || fail 'external export changed'
rm "$XM_LOG/console.log.1"
ln -s "$tmp/export.json" "$XM_LOG/system-update-schedule.log.2"
reject platform_clean_uninstall_preflight
[[ $(cat "$tmp/export.json") == 'external export' ]] || fail 'new schedule log symlink changed export'
rm "$XM_LOG/system-update-schedule.log.2"
platform_clean_uninstall
for p in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG" "$XM_ROOT/usr/local/bin/xy"; do [[ ! -e $p ]] || fail "retained own path $p"; done
[[ -f $tmp/export.json && -d $XM_ROOT/usr/local/bin ]] || fail 'external export/standard directory preservation'
# All package manager commands below are controlled executables in a private PATH.
mkdir -p "$tmp/mockbin"
export TEST_CLEAN_FIXTURE=$tmp
cat > "$tmp/mockbin/dpkg-query" <<'MOCK'
#!/bin/sh
case "$*" in *Essential*) printf 'bash\tyes\na\tno\nb\tno\nz\tno\n' ;; *) printf 'bash\tinstalled\na\tinstalled\nb\tinstalled\nz\tinstalled\n'; [ ! -f "$TEST_CLEAN_FIXTURE/debian-extra-installed" ] || printf 'c\tinstalled\n' ;; esac
MOCK
cat > "$tmp/mockbin/apt-cache" <<'MOCK'
#!/bin/sh
printf '%s\nReverse Depends:\n' "$3"
[ "$3" != b ] || printf '  z\n'
MOCK
cat > "$tmp/mockbin/apt-get" <<'MOCK'
#!/bin/sh
case "$*" in *--simulate*) if [ -f "$TEST_CLEAN_FIXTURE/bad-simulation" ]; then printf 'Purg z [1.0]\n'; else printf 'Purg a [1.0]\n'; fi ;; *) printf '%s\n' "$*" > "$TEST_CLEAN_FIXTURE/purge-invocation" ;; esac
MOCK
cat > "$tmp/mockbin/getent" <<'MOCK'
#!/bin/sh
printf 'root:x:0:0:root:/root:/bin/sh\n'
MOCK
chmod 0755 "$tmp/mockbin/"*
export PATH="$tmp/mockbin:$PATH"
export XM_OS=debian
printf '{"owner":"xray-manager:1","os":"debian","baseline":["bash","z"],"added":["a","b","bash"]}\n' > "$tmp/ledger.json"
[[ $(_platform_dependency_plan "$tmp/ledger.json") == a ]] || fail 'shared/baseline package plan'
touch "$tmp/bad-simulation"
reject _platform_dependency_plan "$tmp/ledger.json"
(
    export PYTHONOPTIMIZE=1
    reject _platform_dependency_plan "$tmp/ledger.json"
)
[[ ! -e $tmp/purge-invocation ]] || fail 'simulation failure mutated packages'
rm "$tmp/bad-simulation"
# Explicit fixture overrides: verify mutation argv without invoking a real manager.
_platform_real() { return 0; }
platform_detect() { XM_OS=debian; }
platform_dependency_cleanup "$tmp/ledger.json"
[[ $(cat "$tmp/purge-invocation") == '--no-auto-remove purge -y -- a' ]] || fail 'purge exceeded ledger or used autoremove'
touch "$tmp/debian-extra-installed"
printf '{"owner":"xray-manager:1","os":"debian","baseline":["bash","z"],"added":["a","c"]}\n' > "$tmp/debian-request-ledger.json"
[[ $(_platform_dependency_plan "$tmp/debian-request-ledger.json") == $'a\nc' ]] || fail 'Debian plan changed simulated request argv'
platform_dependency_cleanup "$tmp/debian-request-ledger.json"
[[ $(cat "$tmp/purge-invocation") == '--no-auto-remove purge -y -- a c' ]] || fail 'Debian cleanup argv differed from simulation'
rm "$tmp/debian-extra-installed"
printf '{"owner":"foreign","os":"debian","baseline":[],"added":["a"]}\n' > "$tmp/bad-ledger.json"
reject _platform_dependency_plan "$tmp/bad-ledger.json"
(
    export PYTHONOPTIMIZE=1
    reject _platform_dependency_plan "$tmp/bad-ledger.json"
)
printf 'PASS: complete own-file cleanup, unknown/symlink/export protection, package ledger/baseline/reverse dependency and simulation boundaries\n'

# Alpine apk del prunes unused dependencies even when they are absent from its
# argv. The plan must preserve an externally needed dependency by retaining
# its world anchor, then execute the exact safe argv that was simulated.
(
    cat > "$tmp/mockbin/apk" <<'MOCK'
#!/bin/sh
case "$1:$2" in
    info:)
        printf 'base\nanchor\ndep\nretained\nsafe\n' ;;
    info:--rdepends)
        printf '%s-1 is required by:\n' "$3"
        [ "$3" != retained ] || printf 'base-1\n' ;;
    del:--simulate)
        shift 3
        if [ -f "$TEST_CLEAN_FIXTURE/apk-fail" ]; then exit 93; fi
        if [ -f "$TEST_CLEAN_FIXTURE/apk-install" ]; then printf '(1/1) Installing foreign (1)\n'; exit 0; fi
        if [ -f "$TEST_CLEAN_FIXTURE/apk-upgrade" ]; then printf '(1/1) Upgrading foreign (1)\n'; exit 0; fi
        if [ -f "$TEST_CLEAN_FIXTURE/apk-unknown-action" ]; then printf '(1/1) Replacing safe (1)\n'; exit 0; fi
        if [ -f "$TEST_CLEAN_FIXTURE/apk-unknown-package" ]; then printf '(1/1) Purging foreign (1)\n'; exit 0; fi
        if [ -f "$TEST_CLEAN_FIXTURE/apk-baseline" ]; then printf '(1/1) Purging base (1)\n'; exit 0; fi
        if [ -f "$TEST_CLEAN_FIXTURE/apk-drift" ] && [ "$*" = 'dep safe' ]; then
            if [ -f "$TEST_CLEAN_FIXTURE/apk-drift-seen" ]; then
                printf '(1/2) Purging dep (1)\n(2/2) Purging safe (1)\n'
                exit 0
            fi
            : > "$TEST_CLEAN_FIXTURE/apk-drift-seen"
        fi
        for package do
            case $package in
                anchor) printf '(1/2) Purging anchor (1)\n(2/2) Purging retained (1)\n' ;;
                safe) printf '(1/1) Purging safe (1)\n' ;;
            esac
        done ;;
    del:--)
        shift 2
        printf '%s\n' "$*" > "$TEST_CLEAN_FIXTURE/apk-delete-invocation" ;;
    *) exit 90 ;;
esac
MOCK
    chmod 0755 "$tmp/mockbin/apk"
    export XM_OS=alpine
    printf '{"owner":"xray-manager:1","os":"alpine","baseline":["base"],"added":["anchor","dep","retained","safe"]}\n' > "$tmp/alpine-ledger.json"
    _platform_real() { return 0; }
    platform_detect() { XM_OS=alpine; }
    plan=$(_platform_dependency_plan "$tmp/alpine-ledger.json" 2> "$tmp/alpine-plan.stderr") || fail 'Alpine safe subset rejected'
    [[ $plan == $'dep\nsafe' ]] || fail "Alpine plan did not preserve protected dependency: $plan"
    grep -q 'anchor, dep, retained' "$tmp/alpine-plan.stderr" || fail 'Alpine retained packages not reported'
    platform_dependency_cleanup "$tmp/alpine-ledger.json" || fail 'Alpine safe subset cleanup failed'
    [[ $(cat "$tmp/apk-delete-invocation") == 'dep safe' ]] || fail 'Alpine cleanup argv differed from verified plan'
    for bad in apk-fail apk-install apk-upgrade apk-unknown-action apk-unknown-package; do
        touch "$tmp/$bad"
        reject _platform_dependency_plan "$tmp/alpine-ledger.json"
        if [[ $bad == apk-unknown-action ]]; then
            (export PYTHONOPTIMIZE=1; reject _platform_dependency_plan "$tmp/alpine-ledger.json")
        fi
        rm "$tmp/$bad"
    done
    touch "$tmp/apk-drift"
    reject _platform_dependency_plan "$tmp/alpine-ledger.json"
    rm "$tmp/apk-drift" "$tmp/apk-drift-seen"
    touch "$tmp/apk-baseline"
    [[ -z $(_platform_dependency_plan "$tmp/alpine-ledger.json") ]] || fail 'Alpine baseline deletion was accepted'
    rm "$tmp/apk-baseline"
    rm "$tmp/apk-delete-invocation"
    (
        _platform_dependency_plan() {
            if [[ -e $tmp/recheck-seen ]]; then return 1; fi
            : > "$tmp/recheck-seen"
            printf 'safe\n'
        }
        reject platform_dependency_cleanup "$tmp/alpine-ledger.json"
    )
    [[ ! -e $tmp/apk-delete-invocation ]] || fail 'Alpine cleanup ignored failed immediate recheck'
)
printf 'PASS: Alpine simulated safe request subset, protected orphan retention and exact cleanup argv\n'

# Optimized Python must not adopt or overwrite a foreign dependency ledger.
(
    export PYTHONOPTIMIZE=1
    XM_ETC=$tmp/record-etc
    mkdir -p "$XM_ETC"
    printf '{"owner":"foreign","os":"debian","baseline":["a"],"added":[]}\n' > "$XM_ETC/dependency-ledger.json"
    cp "$XM_ETC/dependency-ledger.json" "$tmp/foreign-ledger-before"
    _platform_paths() { return 0; }
    _platform_owned_dir() { return 0; }
    _platform_package_inventory() { printf '{"os":"debian","packages":["a","b"]}\n'; }
    _XM_DEPENDENCY_BEFORE='{"os":"debian","packages":["a"]}'
    reject _platform_dependency_record
    cmp "$XM_ETC/dependency-ledger.json" "$tmp/foreign-ledger-before" || fail 'optimized Python overwrote foreign dependency ledger'
)
printf 'PASS: optimized Python rejects foreign dependency ledger without overwrite\n'

# Alpine adduser legitimately includes its own account in the dedicated group.
# Simulate passwd/group/process queries; do not inspect or delete host accounts.
(
    export XM_ROOT=''
    XM_DATA=$tmp/account-data
    mkdir "$XM_DATA"
    printf 'xray-manager:1\n' > "$XM_DATA/.xray-manager-account"
    test_members=xray-manager
    test_other=''
    getent() {
        case $1:$# in
            passwd:2) printf 'xray-manager:x:100:102::/var/lib/xray-manager:/sbin/nologin\n' ;;
            group:2) printf 'xray-manager:x:102:%s\n' "$test_members" ;;
            passwd:1) printf 'root:x:0:0:root:/root:/bin/sh\nxray-manager:x:100:102::/var/lib/xray-manager:/sbin/nologin\n'; [[ -z $test_other ]] || printf '%s\n' "$test_other" ;;
        esac
        return 0
    }
    python3() { if [[ $1 == - && $2 == 100 ]]; then cat >/dev/null; return 0; else command python3 "$@"; fi; }
    _platform_clean_account_preflight
    test_members=''
    _platform_clean_account_preflight
    test_members=xray-manager,other
    reject _platform_clean_account_preflight
    test_members=xray-manager
    test_other='other:x:101:102::/home/other:/bin/sh'
    reject _platform_clean_account_preflight
)
printf 'PASS: Alpine own group membership accepted; external group/UID/GID sharing rejected (account/process fixtures)\n'
# POSIX-only inventory can snapshot before Python/jq are installed; explicit
# snapshot is noclobber, and implicit snapshot emits no machine data to the UI.
platform_dependencies_snapshot "$tmp/packages-before.json"
python3 - "$tmp/packages-before.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]));assert j['os']=='debian' and set(j['packages'])=={'bash','a','b','z'}
PY
reject platform_dependencies_snapshot "$tmp/packages-before.json"
[[ -z $(platform_dependencies_snapshot) ]] || fail 'implicit snapshot polluted stdout'
printf 'PASS: dependency snapshot JSON/noclobber and quiet implicit baseline\n'

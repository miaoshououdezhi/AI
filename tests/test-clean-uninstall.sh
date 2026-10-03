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
printf 'core\n' > "$XM_BIN"
printf '{"nodes":[]}\n' > "$XM_ETC/state.json"
printf 'log\n' > "$XM_LOG/console.log"
printf 'native failure\n' > "$XM_ETC/last-error.log"
printf 'native extra failure\n' > "$XM_ETC/last-extra-error.log"
printf 'external export\n' > "$tmp/export.json"
platform_shortcut_install
platform_clean_uninstall_preflight
printf 'foreign preserved\n' > "$XM_ETC/foreign.conf"
reject platform_clean_uninstall_preflight
[[ $(cat "$XM_ETC/foreign.conf") == 'foreign preserved' && -f $XM_BIN ]] || fail 'foreign preflight mutation'
rm "$XM_ETC/foreign.conf"
ln -s "$tmp/export.json" "$XM_LOG/console.log.1"
reject platform_clean_uninstall_preflight
[[ $(cat "$tmp/export.json") == 'external export' ]] || fail 'external export changed'
rm "$XM_LOG/console.log.1"
platform_clean_uninstall
for p in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG" "$XM_ROOT/usr/local/bin/xy"; do [[ ! -e $p ]] || fail "retained own path $p"; done
[[ -f $tmp/export.json && -d $XM_ROOT/usr/local/bin ]] || fail 'external export/standard directory preservation'
# All package manager commands below are controlled executables in a private PATH.
mkdir -p "$tmp/mockbin"
export TEST_CLEAN_FIXTURE=$tmp
cat > "$tmp/mockbin/dpkg-query" <<'MOCK'
#!/bin/sh
case "$*" in *Essential*) printf 'bash\tyes\na\tno\nb\tno\nz\tno\n' ;; *) printf 'bash\tinstalled\na\tinstalled\nb\tinstalled\nz\tinstalled\n' ;; esac
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
[[ ! -e $tmp/purge-invocation ]] || fail 'simulation failure mutated packages'
rm "$tmp/bad-simulation"
# Explicit fixture overrides: verify mutation argv without invoking a real manager.
_platform_real() { return 0; }
platform_detect() { XM_OS=debian; }
platform_dependency_cleanup "$tmp/ledger.json"
[[ $(cat "$tmp/purge-invocation") == '--no-auto-remove purge -y -- a' ]] || fail 'purge exceeded ledger or used autoremove'
printf '{"owner":"foreign","os":"debian","baseline":[],"added":["a"]}\n' > "$tmp/bad-ledger.json"
reject _platform_dependency_plan "$tmp/bad-ledger.json"
printf 'PASS: complete own-file cleanup, unknown/symlink/export protection, package ledger/baseline/reverse dependency and simulation boundaries\n'

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

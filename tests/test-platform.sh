#!/usr/bin/env bash
# Self-contained isolation tests. No package installation or real init operations.
set -euo pipefail
TEST_REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$TEST_REPO/lib/platform.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/xray-platform-tests.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
XM_ROOT=$TEST_ROOT/root
mkdir -p "$XM_ROOT/etc"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail() { if "$@" >"$TEST_ROOT/failure.stdout" 2>"$TEST_ROOT/failure.stderr"; then fail "unexpected success: $*"; fi; }
uname() { printf '%s\n' "${TEST_MACHINE:-x86_64}"; }
for os in 'debian 12' 'debian 13' 'alpine 3.23.4' 'alpine 3.24.0'; do
    read -r id ver <<< "$os"
    printf 'ID=%s\nVERSION_ID="%s"\n' "$id" "$ver" > "$XM_ROOT/etc/os-release"
    platform_detect
    [[ $XM_OS == "$id" && $XM_OS_VERSION == "$ver" && $XM_ARCH == amd64 ]] || fail 'OS detection'
done
TEST_MACHINE=aarch64
platform_detect
[[ $XM_ARCH == arm64 ]] || fail 'ARM detection'
TEST_MACHINE=riscv64
expect_fail platform_detect
TEST_MACHINE=x86_64
printf 'ID=debian\nVERSION_ID=11\n' > "$XM_ROOT/etc/os-release"
expect_fail platform_detect
printf 'ID=alpine\nVERSION_ID=3.23.4\n' > "$XM_ROOT/etc/os-release"
platform_detect
platform_prepare
platform_prepare
for dir in "$XM_HOME" "$XM_ETC" "$XM_DATA" "$XM_LOG"; do _platform_owned_dir "$dir" || fail 'ownership'; done
expect_fail platform_service start
expect_fail platform_dependencies
expect_fail platform_install_service
expect_fail platform_remove_service
expect_fail platform_port_available 0
expect_fail platform_port_available 65536
expect_fail platform_port_available '80;id'
expect_fail platform_logs '50;id'
expect_fail platform_fetch_core 'v1.0.0;id' "$TEST_ROOT/bad-version"
# System update uses only in-process package stubs. Never invoke a host package
# manager, even if a regression bypasses the XM_ROOT/root guard.
run_system_update_guard() (
    apt-get() { printf 'unexpected apt-get\n' >> "$TEST_ROOT/update-commands"; return 99; }
    apk() { printf 'unexpected apk\n' >> "$TEST_ROOT/update-commands"; return 99; }
    platform_system_update "$@"
)
: > "$TEST_ROOT/update-commands"
expect_fail run_system_update_guard
grep -q 'XM_ROOT' "$TEST_ROOT/failure.stderr" || fail 'system update did not reject XM_ROOT'
[[ ! -s $TEST_ROOT/update-commands ]] || fail 'system update reached a package manager in XM_ROOT mode'
expect_fail run_system_update_guard unexpected
grep -q '不接受参数' "$TEST_ROOT/failure.stderr" || fail 'system update accepted arguments'
[[ ! -s $TEST_ROOT/update-commands ]] || fail 'system update reached a package manager with arguments'

run_system_update_stub() (
    # Permit the fixture root only here, after testing the production guard.
    _platform_real() { printf 'real-check\n' >> "$TEST_ROOT/update-gates"; return "${TEST_REAL_STATUS:-0}"; }
    apt-get() {
        printf 'apt-get:%s:frontend=%s\n' "$*" "${DEBIAN_FRONTEND:-}" >> "$TEST_ROOT/update-commands"
        printf 'apt stdout: %s\n' "$*"
        printf 'apt stderr: %s\n' "$*" >&2
        case "$*:$TEST_FAIL_STAGE" in
            '--error-on=any update:update') return 17 ;;
            '--error-on=any update:strict-update')
                printf 'E: Failed to fetch fixture repository index\n' >&2
                return 100 ;;
            'upgrade --with-new-pkgs -y:upgrade') return 23 ;;
        esac
    }
    apk() {
        printf 'apk:%s\n' "$*" >> "$TEST_ROOT/update-commands"
        printf 'apk stdout: %s\n' "$*"
        printf 'apk stderr: %s\n' "$*" >&2
        case "$*:$TEST_FAIL_STAGE" in update:update) return 19 ;; upgrade:upgrade) return 29 ;; esac
    }
    platform_system_update > "$TEST_ROOT/update.stdout" 2> "$TEST_ROOT/update.stderr"
)
for fixture in 'debian 12' 'debian 13' 'alpine 3.23.4' 'alpine 3.24.0'; do
    read -r id ver <<< "$fixture"
    printf 'ID=%s\nVERSION_ID="%s"\n' "$id" "$ver" > "$XM_ROOT/etc/os-release"
    : > "$TEST_ROOT/update-commands"
    : > "$TEST_ROOT/update-gates"
    TEST_FAIL_STAGE='' run_system_update_stub || fail "$id system update failed with package stubs"
    [[ $(cat "$TEST_ROOT/update-gates") == real-check ]] || fail "$id did not run real/root guard first"
    if [[ $id == debian ]]; then
        [[ $(cat "$TEST_ROOT/update-commands") == $'apt-get:--error-on=any update:frontend=\napt-get:upgrade --with-new-pkgs -y:frontend=noninteractive' ]] || fail 'Debian update command order or flags'
        grep -q 'apt stdout: upgrade --with-new-pkgs -y' "$TEST_ROOT/update.stdout" || fail 'Debian stdout hidden'
        grep -q 'apt stderr: upgrade --with-new-pkgs -y' "$TEST_ROOT/update.stderr" || fail 'Debian stderr hidden'
    else
        [[ $(cat "$TEST_ROOT/update-commands") == $'apk:update\napk:upgrade' ]] || fail 'Alpine update command order or flags'
        grep -q 'apk stdout: upgrade' "$TEST_ROOT/update.stdout" || fail 'Alpine stdout hidden'
        grep -q 'apk stderr: upgrade' "$TEST_ROOT/update.stderr" || fail 'Alpine stderr hidden'
    fi
    for stage in update upgrade; do
        : > "$TEST_ROOT/update-commands"
        if TEST_FAIL_STAGE=$stage run_system_update_stub; then fail "$id $stage failure returned success"; else result=$?; fi
        if [[ $id == debian ]]; then
            [[ $result -eq $([[ $stage == update ]] && printf 17 || printf 23) ]] || fail 'Debian failure exit status lost'
            grep -q "APT 软件包.*失败（退出码 ${result}）" "$TEST_ROOT/update.stderr" || fail 'Debian failure stage hidden'
        else
            [[ $result -eq $([[ $stage == update ]] && printf 19 || printf 29) ]] || fail 'Alpine failure exit status lost'
            grep -q "APK 软件包.*失败（退出码 ${result}）" "$TEST_ROOT/update.stderr" || fail 'Alpine failure stage hidden'
        fi
        if [[ $stage == update ]]; then
            [[ $(wc -l < "$TEST_ROOT/update-commands") -eq 1 ]] || fail "$id upgraded after index failure"
        fi
    done
    if [[ $id == debian ]]; then
        : > "$TEST_ROOT/update-commands"
        if TEST_FAIL_STAGE=strict-update run_system_update_stub; then fail 'Debian partial index failure returned success'; else result=$?; fi
        [[ $result -eq 100 ]] || fail 'Debian partial index failure exit status lost'
        [[ $(cat "$TEST_ROOT/update-commands") == 'apt-get:--error-on=any update:frontend=' ]] || fail 'Debian upgraded after a partial index failure'
        grep -q 'Failed to fetch fixture repository index' "$TEST_ROOT/update.stderr" || fail 'Debian repository failure output hidden'
        grep -q 'APT 软件包索引更新失败（退出码 100）' "$TEST_ROOT/update.stderr" || fail 'Debian strict index failure stage hidden'
    fi
done
printf 'ID=debian\nVERSION_ID=12\n' > "$XM_ROOT/etc/os-release"
: > "$TEST_ROOT/update-commands"
if TEST_FAIL_STAGE='' TEST_REAL_STATUS=7 run_system_update_stub; then fail 'root guard failure returned success'; else result=$?; fi
[[ $result -ne 0 && ! -s $TEST_ROOT/update-commands ]] || fail 'root guard failure reached a package manager'
printf 'ID=debian\nVERSION_ID=11\n' > "$XM_ROOT/etc/os-release"
: > "$TEST_ROOT/update-commands"
if TEST_FAIL_STAGE='' run_system_update_stub; then fail 'unsupported system update succeeded'; fi
grep -q '不支持的系统' "$TEST_ROOT/update.stderr" || fail 'unsupported system error missing'
[[ ! -s $TEST_ROOT/update-commands ]] || fail 'unsupported system reached a package manager'
run_system_update_unknown() (
    _platform_real() { return 0; }
    platform_detect() { XM_OS=unknown; }
    apt-get() { printf 'unexpected apt-get\n' >> "$TEST_ROOT/update-commands"; return 99; }
    apk() { printf 'unexpected apk\n' >> "$TEST_ROOT/update-commands"; return 99; }
    platform_system_update
)
expect_fail run_system_update_unknown
grep -q '不支持的系统：unknown。' "$TEST_ROOT/failure.stderr" || fail 'unknown OS fallback diagnostic'
[[ ! -s $TEST_ROOT/update-commands ]] || fail 'unknown OS fallback reached a package manager'
printf 'ID=alpine\nVERSION_ID=3.23.4\n' > "$XM_ROOT/etc/os-release"
printf 'PASS: guarded system update, Debian/Alpine order, output, failure status and unsupported OS\n'
# Refuse foreign directories and symlink ancestors without touching their contents.
(
    unset XM_HOME XM_ETC XM_DATA XM_LOG XM_BIN
    XM_ROOT=$TEST_ROOT/foreign
    mkdir -p "$XM_ROOT/etc/xray-manager"
    printf 'retain\n' > "$XM_ROOT/etc/xray-manager/other-file"
    expect_fail platform_prepare
    [[ $(cat "$XM_ROOT/etc/xray-manager/other-file") == retain ]] || fail 'foreign data changed'
)
(
    unset XM_HOME XM_ETC XM_DATA XM_LOG XM_BIN
    XM_ROOT=$TEST_ROOT/symlink
    mkdir -p "$XM_ROOT" "$TEST_ROOT/foreign-home"
    ln -s "$TEST_ROOT/foreign-home" "$XM_ROOT/opt"
    expect_fail platform_prepare
)
# Genuine ZIP parser/hash tests with generated small ELF fixtures and a local curl stub.
mkdir -p "$TEST_ROOT/mockbin" "$TEST_ROOT/fixtures"
cat > "$TEST_ROOT/mockbin/curl" <<'MOCK'
#!/usr/bin/env bash
set -eu
out=''
while (($#)); do
    if [[ $1 == --output ]]; then out=$2; shift 2; else last=$1; shift; fi
done
[[ $last == https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip* ]] || exit 1
if [[ $last == *.dgst ]]; then cp "$TEST_FIXTURES/core.dgst" "$out"; else cp "$TEST_FIXTURES/core.zip" "$out"; fi
MOCK
chmod 0755 "$TEST_ROOT/mockbin/curl"
export TEST_FIXTURES=$TEST_ROOT/fixtures
export PATH="$TEST_ROOT/mockbin:$PATH"
make_fixture() {
    python3 - "$TEST_FIXTURES" "$1" <<'PY'
import hashlib, pathlib, stat, struct, sys, zipfile
p=pathlib.Path(sys.argv[1]); mode=sys.argv[2]
head=bytearray(64); head[:6]=b'\x7fELF\x02\x01'; struct.pack_into('<H',head,18,62 if mode!='wrong-arch' else 183)
with zipfile.ZipFile(p/'core.zip','w') as z:
    z.writestr('xray', bytes(head)+b'x'*256)
    if mode=='traversal': z.writestr('../escape','forbidden')
    if mode=='symlink':
        i=zipfile.ZipInfo('evil'); i.external_attr=(stat.S_IFLNK|0o777)<<16; z.writestr(i,'/etc/passwd')
    if mode=='duplicate': z.writestr('xray',bytes(head))
h=hashlib.sha256((p/'core.zip').read_bytes()).hexdigest()
if mode=='digest': h='0'*64
(p/'core.dgst').write_text('MD5= ignored\nSHA2-256= '+h+'\nSHA2-512= ignored\n')
PY
}
make_fixture good
platform_fetch_core v26.3.27 "$TEST_ROOT/verified-core"
[[ -x $TEST_ROOT/verified-core ]] || fail 'core not executable'
expect_fail platform_fetch_core v26.3.27 "$TEST_ROOT/verified-core"
for fixture in digest traversal symlink duplicate wrong-arch; do
    make_fixture "$fixture"
    expect_fail platform_fetch_core v26.3.27 "$TEST_ROOT/rejected-$fixture"
    [[ ! -e $TEST_ROOT/rejected-$fixture ]] || fail 'rejected core persisted'
done
[[ ! -e $TEST_ROOT/escape ]] || fail 'archive traversal'
# ss conflicts: both transports considered, leading-zero ports normalized, execution rejected.
ss() {
    case ${TEST_LISTENER:-none}:$* in
        tcp:*'-ltn'*) printf 'LISTEN 0 1 0.0.0.0:8000 0.0.0.0:*\n' ;;
        udp:*'-lun'*) printf 'UNCONN 0 0 0.0.0.0:8000 0.0.0.0:*\n' ;;
    esac
    return 0
}
platform_port_available 08000
TEST_LISTENER=tcp
expect_fail platform_port_available 8000
TEST_LISTENER=udp
expect_fail platform_port_available 8000


# Read-only interactive helpers: real JSON/IP parsing behind controlled HTTPS fixtures.
export TEST_HELPER_DIR=$TEST_ROOT/helpers
mkdir -p "$TEST_HELPER_DIR"
python3 - "$TEST_HELPER_DIR" <<'PY'
import datetime, json, pathlib, sys
p=pathlib.Path(sys.argv[1])
rows=[]
for i in range(100):
    published=(datetime.datetime(2026,9,30)-datetime.timedelta(days=i)).strftime('%Y-%m-%dT%H:%M:%SZ')
    rows.append({'draft':False,'prerelease':True,'tag_name':'v26.9.'+str(i+1),'published_at':published})
(p/'page-1.json').write_text(json.dumps(list(reversed(rows))))
(p/'page-2.json').write_text(json.dumps([
 {'draft':True,'tag_name':'malicious\tignored'},
 {'draft':False,'prerelease':False,'tag_name':'v26.3.27','published_at':'2026-03-27T17:51:00Z'},
 {'draft':False,'prerelease':False,'tag_name':'v26.2.6','published_at':'2026-02-06T10:00:00Z'},
 {'draft':False,'prerelease':False,'tag_name':'v99.0.0','published_at':'2020-01-01T00:00:00Z'},
 {'draft':False,'prerelease':True,'tag_name':'v26.10.1-beta','published_at':'2026-10-01T00:00:00Z'}]))
(p/'bad-bool.json').write_text(json.dumps([{'draft':False,'prerelease':'false','tag_name':'v1.2.3','published_at':'2026-01-01T00:00:00Z'}]))
(p/'bad-date.json').write_text(json.dumps([{'draft':False,'prerelease':False,'tag_name':'v1.2.3','published_at':'2026-02-31T00:00:00Z'}]))
(p/'bad-tag.json').write_text(json.dumps([{'draft':False,'prerelease':False,'tag_name':'v1.2.3;id','published_at':'2026-01-01T00:00:00Z'}]))
(p/'rate-limit.json').write_text('{"message":"API rate limit"}')
(p/'invalid-json.json').write_text('[malformed')
PY
cat > "$TEST_ROOT/mockbin/curl" <<'MOCKHELPER'
#!/usr/bin/env bash
set -eu
out=''
while (($#)); do
    if [[ $1 == --output ]]; then out=$2; shift 2; else url=$1; shift; fi
done
printf '%s\n' "$url" >> "$TEST_HELPER_DIR/requests"
case $url in
    'https://api.github.com/repos/XTLS/Xray-core/releases?per_page=100&page='*)
        case ${TEST_HELPER_MODE:-normal} in
            http-failure) exit 22 ;;
            invalid-json|rate-limit|bad-bool|bad-date|bad-tag) cp "$TEST_HELPER_DIR/$TEST_HELPER_MODE.json" "$out" ;;
            endless) cp "$TEST_HELPER_DIR/page-1.json" "$out" ;;
            missing-preview) printf '[{"draft":false,"prerelease":false,"tag_name":"v1.0.0","published_at":"2026-01-01T00:00:00Z"}]\n' > "$out" ;;
            *) cp "$TEST_HELPER_DIR/page-${url##*=}.json" "$out" ;;
        esac ;;
    https://api.ipify.org|https://api64.ipify.org|https://icanhazip.com)
        case ${TEST_HELPER_MODE:-ipv4} in
            ip-http-failure) exit 22 ;;
            ipv4) printf '8.8.8.8\n' > "$out" ;;
            ipv6) printf '2001:4860:4860::8888\n' > "$out" ;;
            ip-fallback) if [[ $url == https://api.ipify.org ]]; then printf '192.168.1.1' > "$out"; else printf '1.1.1.1' > "$out"; fi ;;
            private-ip) printf '10.1.2.3' > "$out" ;;
            mapped-private) printf '::ffff:192.168.1.1' > "$out" ;;
            multicast) printf '224.0.0.1' > "$out" ;;
            scoped-ipv6) printf '2001:4860::1%%eth0' > "$out" ;;
            ip-injection) printf '8.8.8.8\033[31m' > "$out" ;;
            ip-nul) printf '8.8.8.8\000' > "$out" ;;
            *) exit 1 ;;
        esac ;;
    *) exit 1 ;;
esac
MOCKHELPER
chmod 0755 "$TEST_ROOT/mockbin/curl"
export TEST_HELPER_MODE=normal
choices=$(platform_release_choices)
expected=$'stable\tv26.3.27\t2026-03-27T17:51:00Z\nstable\tv26.2.6\t2026-02-06T10:00:00Z\npreview\tv26.9.1\t2026-09-30T00:00:00Z\npreview\tv26.9.2\t2026-09-29T00:00:00Z'
[[ $choices == "$expected" ]] || fail 'published order, draft filtering, pagination, safe tag filtering'
for TEST_HELPER_MODE in http-failure invalid-json rate-limit bad-bool bad-date bad-tag endless; do
    export TEST_HELPER_MODE
    expect_fail platform_release_choices
    [[ ! -s $TEST_ROOT/failure.stdout ]] || fail 'partial release choices on failure'
done
TEST_HELPER_MODE='missing-preview'
[[ $(platform_release_choices) == $'stable\tv1.0.0\t2026-01-01T00:00:00Z' ]] || fail 'missing preview invented'
TEST_HELPER_MODE=ipv4
[[ $(platform_public_ip) == 8.8.8.8 ]] || fail 'IPv4 detection'
TEST_HELPER_MODE=ipv6
[[ $(platform_public_ip) == 2001:4860:4860::8888 ]] || fail 'IPv6 detection'
TEST_HELPER_MODE=ip-fallback
[[ $(platform_public_ip) == 1.1.1.1 ]] || fail 'public IP fallback'
for TEST_HELPER_MODE in ip-http-failure private-ip mapped-private multicast scoped-ipv6 ip-injection ip-nul; do
    export TEST_HELPER_MODE
    expect_fail platform_public_ip
    [[ ! -s $TEST_ROOT/failure.stdout ]] || fail 'unsafe IP printed'
done
# Bounded random selection retries state collisions and listeners; never selects <1024.
openssl() {
    [[ $* == 'rand -hex 2' ]] || return 1
    case ${TEST_RANDOM_MODE:-normal} in
        normal) printf '0000\n' ;;
        collision) if [[ ! -e $TEST_HELPER_DIR/random-used ]]; then touch "$TEST_HELPER_DIR/random-used"; printf '0000\n'; else printf '0001\n'; fi ;;
        exhausted) printf 'ffff\n' ;;
        malformed) printf '0000;id\n' ;;
        error) return 1 ;;
    esac
}
TEST_LISTENER=none
printf '{"nodes":[]}\n' > "$TEST_HELPER_DIR/state.json"
[[ $(platform_random_port "$TEST_HELPER_DIR/state.json") == 1024 ]] || fail 'non-privileged random port'
printf '{"nodes":[{"port":1024}]}\n' > "$TEST_HELPER_DIR/state.json"
TEST_RANDOM_MODE=collision
[[ $(platform_random_port "$TEST_HELPER_DIR/state.json") == 1025 ]] || fail 'state collision retry'
for TEST_RANDOM_MODE in exhausted malformed error; do
    expect_fail platform_random_port "$TEST_HELPER_DIR/state.json"
    [[ ! -s $TEST_ROOT/failure.stdout ]] || fail 'bad random port printed'
done
TEST_RANDOM_MODE=normal
printf '{"nodes":[{"port":true}]}\n' > "$TEST_HELPER_DIR/state.json"
expect_fail platform_random_port "$TEST_HELPER_DIR/state.json"
expect_fail platform_random_port "$TEST_HELPER_DIR/missing.json"
printf '{"nodes":[]}\n' > "$TEST_HELPER_DIR/state.json"
TEST_LISTENER=tcp
expect_fail platform_random_port "$TEST_HELPER_DIR/state.json"
printf 'PASS: platform matrix, isolation, archive integrity, sockets, release pagination/validation, public IP validation, bounded random selection\n'
# Overview uses only private read fixtures and real Python parsing; untrusted
# OS strings are data, never sourced, and container resource limits win.
mkdir -p "$XM_ROOT/proc/sys/kernel" "$XM_ROOT/proc/self" "$XM_ROOT/sys/fs/cgroup/work"
printf 'PRETTY_NAME="Fixture OS $(touch /should-not-run)"\n' > "$XM_ROOT/etc/os-release"
printf 'host\033[31m\tunsafe\n' > "$XM_ROOT/proc/sys/kernel/hostname"
printf '6.1-fixture\n' > "$XM_ROOT/proc/sys/kernel/osrelease"
printf 'amd64\n' > "$XM_ROOT/proc/sys/kernel/arch"
printf 'model name : Fixture CPU\nprocessor : 0\nprocessor : 1\n' > "$XM_ROOT/proc/cpuinfo"
printf 'Cpus_allowed_list:\t0-7\n' > "$XM_ROOT/proc/self/status"
printf '0::/work\n' > "$XM_ROOT/proc/self/cgroup"
printf 'MemTotal: 1048576 kB\nMemAvailable: 786432 kB\n' > "$XM_ROOT/proc/meminfo"
printf '268435456\n' > "$XM_ROOT/sys/fs/cgroup/work/memory.max"
printf '67108864\n' > "$XM_ROOT/sys/fs/cgroup/work/memory.current"
printf '150000 100000\n' > "$XM_ROOT/sys/fs/cgroup/work/cpu.max"
platform_system_info > "$TEST_ROOT/overview"
[[ $(wc -l < "$TEST_ROOT/overview") -eq 6 ]] || fail 'overview keys/rows'
grep -q 'Memory.*64.0 MiB / 256.0 MiB' "$TEST_ROOT/overview" || fail 'cgroup memory limit/current ignored'
grep -q 'CPU.*2 核' "$TEST_ROOT/overview" || fail 'effective CPU quota ignored'
grep -Fq '$(touch /should-not-run)' "$TEST_ROOT/overview" || fail 'OS literal not preserved as data'
if LC_ALL=C grep -q $'\033' "$TEST_ROOT/overview"; then fail 'overview control character survived'; fi
printf '134217728\n' > "$XM_ROOT/sys/fs/cgroup/memory.max"
printf '33554432\n' > "$XM_ROOT/sys/fs/cgroup/memory.current"
platform_system_info > "$TEST_ROOT/overview"
grep -q 'Memory.*32.0 MiB / 128.0 MiB' "$TEST_ROOT/overview" || fail 'ancestor cgroup limit ignored'
printf 'max\n' > "$XM_ROOT/sys/fs/cgroup/work/memory.max"
printf 'max\n' > "$XM_ROOT/sys/fs/cgroup/memory.max"
platform_system_info > "$TEST_ROOT/overview"
grep -q 'Memory.*256.0 MiB / 1.0 GiB' "$TEST_ROOT/overview" || fail 'unlimited cgroup host fallback incorrect'
printf '268435456\n' > "$XM_ROOT/sys/fs/cgroup/work/memory.max"
printf '999999999999\n' > "$XM_ROOT/sys/fs/cgroup/work/memory.current"
platform_system_info > "$TEST_ROOT/overview"
grep -q 'Memory.*256.0 MiB / 256.0 MiB' "$TEST_ROOT/overview" || fail 'memory current not clamped'
printf 'max\n' > "$XM_ROOT/sys/fs/cgroup/work/memory.max"
printf 'MemTotal: 1048576 kB\n' > "$XM_ROOT/proc/meminfo"
platform_system_info > "$TEST_ROOT/overview"
grep -q $'Memory\t未知' "$TEST_ROOT/overview" || fail 'missing used-memory data invented a value'
rm -rf -- "$XM_ROOT/proc" "$XM_ROOT/sys"
rm -f -- "$XM_ROOT/etc/os-release"
platform_system_info > "$TEST_ROOT/overview"
grep -q $'OS\t未知' "$TEST_ROOT/overview" && grep -q $'Memory\t未知' "$TEST_ROOT/overview" || fail 'missing overview data not unknown'
printf 'PASS: read-only six-field overview sanitizes untrusted OS/host and honors CPU/cgroup memory bounds\n'

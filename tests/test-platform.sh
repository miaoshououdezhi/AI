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

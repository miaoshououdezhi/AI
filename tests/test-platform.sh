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
printf 'PASS: platform matrix, ownership, sandbox refusal, archive integrity/security, TCP/UDP conflict tests\n'

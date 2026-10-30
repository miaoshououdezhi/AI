#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/lib/platform.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/xray-extra-platform.XXXXXXXX")
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if "$@" >"$tmp/out" 2>"$tmp/err"; then fail "unexpected success: $*"; fi; }
for tuple in amd64:glibc amd64:musl arm64:glibc arm64:musl; do
    XM_ARCH=${tuple%:*}; XM_LIBC=${tuple#*:}
    entry=$(_platform_extra_asset)
    [[ $entry == "sing-box-1.14.2-linux-$XM_ARCH-$XM_LIBC"$'\t'* ]] || fail 'arch/libc asset mapping'
done
XM_ARCH=bad; reject _platform_extra_asset
python3 - "$tmp" <<'PY'
import hashlib,io,pathlib,struct,sys,tarfile
p=pathlib.Path(sys.argv[1]);head=bytearray(64);head[:6]=b'\x7fELF\x02\x01';struct.pack_into('<H',head,18,62)
for mode in ('good','traversal','symlink','duplicate','wrongarch'):
 data=bytes(head)
 if mode=='wrongarch':data=data[:18]+struct.pack('<H',183)+data[20:]
 with tarfile.open(p/(mode+'.tgz'),'w:gz') as tar:
  t=tarfile.TarInfo('fixture/sing-box');t.size=len(data);tar.addfile(t,io.BytesIO(data))
  if mode=='traversal':t=tarfile.TarInfo('../escape');t.size=1;tar.addfile(t,io.BytesIO(b'x'))
  if mode=='symlink':t=tarfile.TarInfo('fixture/link');t.type=tarfile.SYMTYPE;t.linkname='/etc/passwd';tar.addfile(t)
  if mode=='duplicate':t=tarfile.TarInfo('fixture/sing-box');t.size=len(data);tar.addfile(t,io.BytesIO(data))
 (p/(mode+'.sha')).write_text(hashlib.sha256((p/(mode+'.tgz')).read_bytes()).hexdigest())
PY
_platform_extra_verify_archive "$tmp/good.tgz" "$(cat "$tmp/good.sha")" fixture amd64 "$tmp/core" "$tmp/hash"
[[ -f $tmp/core && -s $tmp/hash ]] || fail extraction
for bad in traversal symlink duplicate wrongarch; do reject _platform_extra_verify_archive "$tmp/$bad.tgz" "$(cat "$tmp/$bad.sha")" fixture amd64 "$tmp/out-$bad" "$tmp/hash-$bad"; done
reject _platform_extra_verify_archive "$tmp/good.tgz" "$(printf '%064d' 0)" fixture amd64 "$tmp/out-digest" "$tmp/hash-digest"
[[ ! -e $tmp/escape ]] || fail traversal
export XM_ROOT=$tmp/root
reject platform_extra_ensure
reject platform_extra_service bad
# Ensure service templates keep the shared nonroot account and native check.
grep -q '^User=xray-manager$' "$repo/assets/xray-manager-extra.service" || fail 'nonroot systemd'
grep -q '^RestrictAddressFamilies=.*AF_NETLINK' "$repo/assets/xray-manager-extra.service" || fail 'sing-box interface monitor netlink family'
if grep -q '^RestrictAddressFamilies=.*AF_NETLINK' "$repo/assets/xray-manager.service"; then fail 'main Xray address families changed'; fi
grep -q 'sing-box check -c' "$repo/assets/xray-manager-extra.openrc" || fail 'native OpenRC check'
printf 'PASS: pinned extra asset matrix, real archive/digest/ELF parser negatives, host isolation and service contracts\n'
# Rollback removes only newly created verified artifacts. Init operations below
# are mock file operations in a private directory, never host service changes.
platform_prepare
_platform_extra_paths
export XM_INIT=openrc
_platform_real() { return 0; }
_platform_extra_service_path() { printf '%s' "$tmp/unit"; }
platform_extra_remove_service() { rm -f -- "$tmp/unit"; }
cp "$tmp/core" "$XM_EXTRA_BIN"
cp "$tmp/hash" "$XM_ETC/extra-core.sha256"
cp "$repo/assets/xray-manager-extra.openrc" "$tmp/unit"
platform_extra_discard_new 1 1
[[ -f $XM_EXTRA_BIN && -f $tmp/unit ]] || fail 'existing artifacts discarded'
platform_extra_discard_new 0 0
[[ ! -e $XM_EXTRA_BIN && ! -e $XM_ETC/extra-core.sha256 && ! -e $tmp/unit ]] || fail 'new artifacts not discarded'
cp "$tmp/core" "$XM_EXTRA_BIN"
cp "$tmp/hash" "$XM_ETC/extra-core.sha256"
printf '# foreign unit\n' > "$tmp/unit"
reject platform_extra_discard_new 0 0
[[ $(cat "$tmp/unit") == '# foreign unit' && ! -e $XM_EXTRA_BIN ]] || fail 'foreign unit rollback boundary'
printf 'PASS: auxiliary artifact rollback preserves existing/foreign units and removes only new verified binary/hash/unit\n'
# Read-only boot snapshots distinguish a disabled service from an unreadable or
# non-restorable state. All fixed paths and init queries are fixture adapters.
(
    source "$repo/lib/platform.sh"
    mkdir -p "$tmp/enabled-query"
    _platform_paths() { return 0; }
    _platform_init_available() { return 0; }
    _platform_main_resource_preflight() { return 0; }
    platform_extra_preflight() { return 0; }
    _platform_main_service_path() { printf '%s/main' "$tmp/enabled-query"; }
    _platform_extra_service_path() { printf '%s/extra' "$tmp/enabled-query"; }
    _platform_service_enable_link() { printf '%s/%s.link' "$tmp/enabled-query" "$1"; }
    cp "$repo/assets/xray-manager.service" "$tmp/enabled-query/main"
    cp "$repo/assets/xray-manager-extra.service" "$tmp/enabled-query/extra"
    TEST_ENABLED_STATE=enabled; TEST_ENABLED_EXIT=0
    systemctl() {
        [[ $1 == is-enabled && ($2 == xray-manager.service || $2 == xray-manager-extra.service) ]] || return 99
        printf '%s\n' "$TEST_ENABLED_STATE"; return "$TEST_ENABLED_EXIT"
    }
    enabled_exit() {
        local want=$1 which=$2 result=0
        platform_service_enabled "$which" > "$tmp/out" 2> "$tmp/err" || result=$?
        [[ $result == "$want" ]] || fail "enabled $which expected $want got $result"
    }
    XM_INIT=systemd
    for which in main extra; do
        TEST_ENABLED_STATE=enabled; TEST_ENABLED_EXIT=0; enabled_exit 0 "$which"
        TEST_ENABLED_STATE=disabled; TEST_ENABLED_EXIT=1; enabled_exit 1 "$which"
        for state in masked static linked enabled-runtime '' failed; do
            TEST_ENABLED_STATE=$state; TEST_ENABLED_EXIT=1; enabled_exit 2 "$which"
        done
        TEST_ENABLED_STATE=enabled; TEST_ENABLED_EXIT=1; enabled_exit 2 "$which"
        TEST_ENABLED_STATE=disabled; TEST_ENABLED_EXIT=0; enabled_exit 2 "$which"
    done
    XM_INIT=openrc
    for which in main extra; do enabled_exit 1 "$which"; done
    ln -s "$tmp/enabled-query/main" "$tmp/enabled-query/xray-manager.link"
    ln -s "$tmp/enabled-query/extra" "$tmp/enabled-query/xray-manager-extra.link"
    for which in main extra; do enabled_exit 0 "$which"; done
    rm "$tmp/enabled-query/main" "$tmp/enabled-query/xray-manager.link"
    enabled_exit 1 main
    printf '# foreign resource\n' > "$tmp/enabled-query/main"
    enabled_exit 2 main
    enabled_exit 2 invalid
)
printf 'PASS: main/auxiliary boot snapshots, disabled vs unknown states, OpenRC links and owned resource checks\n'
# Human Python messages are tagged/colorized on stderr; machine stdout stays
# parseable. Native PTYs verify TERM/NO_COLOR without any real init operation.
python3 - "$repo/lib/platform.sh" <<'PY'
import errno,json,os,pty,subprocess,sys,threading
program='''source "$1"
_platform_python - <<'BODY'
human('信息','消息')
human('警告','保留依赖')
human('错误','验证失败')
print('{"machine":true}')
BODY
'''
args=['bash','-c',program,'bash',sys.argv[1]]
env=os.environ.copy();env['TERM']='xterm';env.pop('NO_COLOR',None)
r=subprocess.run(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
assert json.loads(r.stdout)=={'machine':True} and b'\x1b' not in r.stdout+r.stderr
assert '[信息] 消息' in r.stderr.decode() and '[警告] 保留依赖' in r.stderr.decode() and '[错误] 验证失败' in r.stderr.decode()
for no_color,term,want_color in ((False,'xterm',True),(True,'xterm',False),(False,'dumb',False)):
 master,slave=pty.openpty();e=env.copy();e['TERM']=term
 if no_color:e['NO_COLOR']=''
 chunks=[]
 def reader():
  while True:
   try:
    data=os.read(master,4096)
    if not data:break
    chunks.append(data)
   except OSError as err:
    if err.errno==errno.EIO:break
    raise
 thread=threading.Thread(target=reader);thread.start()
 child=subprocess.Popen(args,env=e,stdout=subprocess.PIPE,stderr=slave)
 output,_=child.communicate();os.close(slave);thread.join();os.close(master)
 out=b''.join(chunks)
 assert child.returncode==0 and json.loads(output)=={'machine':True} and b'\x1b' not in output
 assert (b'\x1b[38;2;0;255;255m' in out and b'\x1b[38;2;0;191;255m' in out and b'\x1b[38;2;255;0;0m' in out)==want_color, (term,no_color,out)
print('PASS: human Python stderr labels/TTY palette, NO_COLOR/TERM=dumb and clean machine stdout')
PY

# Native Xray HY2 must not be attributed to sing-box. Existing unmarked and
# explicit sing-box HY2 stay on the auxiliary UDP health path.
(
    health_root=$tmp/extra-health
    mkdir -p "$health_root"
    XM_EXTRA_BIN=$health_root/sing-box
    XM_EXTRA_CONFIG=$health_root/extra.json
    XM_ETC=$health_root
    printf '#!/bin/sh\nexit 0\n' > "$XM_EXTRA_BIN"
    chmod 0700 "$XM_EXTRA_BIN"
    printf '{}\n' > "$XM_EXTRA_CONFIG"
    cat > "$XM_ETC/state.json" <<'STATE'
{"nodes":[{"type":"hysteria2","engine":"xray","port":35001},{"type":"hysteria2","port":35004},{"type":"hysteria2","engine":"sing-box","port":35005},{"type":"anytls","port":35006},{"type":"tuicv5","port":35007},{"type":"shadowsocks","port":35002}]}
STATE
    _platform_extra_paths() { return 0; }
    platform_extra_service() { return 0; }
    _platform_python() { cat >/dev/null; printf '5678\n'; }
    readlink() { [[ $1 == /proc/5678/exe ]] || return 1; printf '%s\n' "$XM_EXTRA_BIN"; }
    sleep() { :; }
    HEALTH_CASE=good
    ss() {
        printf '%s\n' "$*" >> "$health_root/socket-calls"
        case "$*" in
            '-H -lunp sport = :35004'|'-H -lunp sport = :35005'|'-H -lunp sport = :35007') ;;
            '-H -ltnp sport = :35006') ;;
            *) return 98 ;;
        esac
        if [[ $* == '-H -lunp sport = :35004' ]]; then
            case $HEALTH_CASE in
                missing) return 0 ;;
                wrong-pid) printf 'UNCONN users:(("xray",pid=1234,fd=9))\n'; return 0 ;;
                command-failed) printf 'UNCONN users:(("sing-box",pid=5678,fd=9))\n'; return 1 ;;
            esac
        fi
        printf 'LISTENER users:(("sing-box",pid=5678,fd=9))\n'
    }
    : > "$health_root/socket-calls"
    platform_extra_health || fail 'legacy HY2 mixed auxiliary health selection'
    [[ $(wc -l < "$health_root/socket-calls") -eq 4 ]] || fail 'extra health queried Xray nodes'
    for HEALTH_CASE in missing wrong-pid command-failed; do
        reject platform_extra_health
    done
)
printf 'PASS: auxiliary health retains legacy/explicit sing-box HY2 UDP ownership and excludes native Xray HY2\n'

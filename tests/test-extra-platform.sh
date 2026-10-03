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

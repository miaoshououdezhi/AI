#!/usr/bin/env bash
# Filesystem-only ownership checks; uses XM_ROOT and never writes host /usr.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/lib/platform.sh"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/xray-shortcut-tests.XXXXXXXX")
test_dir=$(cd "$test_dir" && pwd -P)
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if "$@" >"$test_dir/out" 2>"$test_dir/err"; then fail "unexpected success: $*"; fi; }
export XM_ROOT=$test_dir/root
platform_shortcut_preflight
[[ ! -e $XM_ROOT ]] || fail 'preflight created directories'
platform_shortcut_install
xy=$XM_ROOT/usr/local/bin/xy
[[ -x $xy && -f $xy && ! -L $xy ]] || fail 'entrypoint installation'
_platform_owned_file "$xy" || fail 'ownership marker'
cmp "$repo/assets/xy" "$xy" || fail 'template differs'
platform_shortcut_install
platform_shortcut_remove
platform_shortcut_remove
[[ ! -e $xy && -d ${xy%/*} ]] || fail 'remove/idempotency/directory preservation'
printf 'foreign bytes\n' > "$xy"
reject platform_shortcut_preflight
reject platform_shortcut_install
reject platform_shortcut_remove
[[ $(cat "$xy") == 'foreign bytes' ]] || fail 'foreign entrypoint changed'
rm "$xy"
ln -s "$test_dir/outside" "$xy"
reject platform_shortcut_install
reject platform_shortcut_remove
[[ -L $xy ]] || fail 'foreign symlink deleted'
rm "$xy"
mkdir "$xy"
reject platform_shortcut_install
reject platform_shortcut_remove
rmdir "$xy"
rmdir "$XM_ROOT/usr/local/bin"
mkdir "$test_dir/outside"
printf 'retain\n' > "$test_dir/outside/xy"
ln -s "$test_dir/outside" "$XM_ROOT/usr/local/bin"
reject platform_shortcut_preflight
reject platform_shortcut_install
reject platform_shortcut_remove
[[ $(cat "$test_dir/outside/xy") == retain ]] || fail 'ancestor symlink target changed'
sh -n "$repo/assets/xy"
printf 'PASS: xy installation/repeated update/removal, foreign file/dir/symlink preservation, ancestor rejection and read-only preflight\n'

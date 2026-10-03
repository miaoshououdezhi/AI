#!/usr/bin/env bash
# Actual PTYs verify labels/colors and return-key consumption, not snapshots of
# terminal cosmetics. Redirected streams must stay machine-safe and nonblocking.
set -u
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
source "$repo/lib/common.sh"
XM_UI_RED=; XM_UI_CYAN=; XM_UI_GREEN=; XM_UI_YELLOW=; XM_UI_RESET=
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
{ xm_info info; xm_success success; xm_ok ok; xm_warning warning; xm_error error; } > "$scratch/stdout" 2> "$scratch/stderr"
[[ ! -s $scratch/stdout ]] || fail 'labels polluted stdout'
for label in 信息 成功 OK 警告 错误; do grep -Fq "[$label]" "$scratch/stderr" || fail 'missing label'; done
if LC_ALL=C grep -q $'\033' "$scratch/stderr"; then fail 'redirected logs contain colors'; fi
printf 'untouched\n' > "$scratch/input"
{ xm_pause; IFS= read -r TEST_VALUE; [[ $TEST_VALUE == untouched ]]; } < "$scratch/input" || fail 'pause consumed non-TTY input'
python3 - "$repo" <<'PY'
import errno,os,pty,select,subprocess,sys,time
repo=sys.argv[1]
for mode in ('color','no_color','dumb'):
 master,slave=pty.openpty();env=dict(os.environ);env['TERM']='xterm-256color';env.pop('NO_COLOR',None)
 if mode=='no_color':env['NO_COLOR']=''
 if mode=='dumb':env['TERM']='dumb'
 cmd='source "$1/lib/common.sh"; xm_ui_init; xm_info info; xm_success success; xm_ok ok; xm_warning warning; xm_error error; xm_pause; printf "RETURNED\\n" >&2'
 p=subprocess.Popen(['bash','-c',cmd,'--',repo],stdin=slave,stderr=slave,stdout=subprocess.DEVNULL,env=env)
 os.close(slave);data=b''; deadline=time.monotonic()+5;sent=False
 while time.monotonic()<deadline:
  if not select.select([master],[],[],0.05)[0]:continue
  try:chunk=os.read(master,8192)
  except OSError as e:
   if e.errno==errno.EIO:break
   raise
  if not chunk:break
  data+=chunk
  if '按任意键返回主菜单'.encode() in data and not sent:
   assert b'RETURNED' not in data;os.write(master,b'x');sent=True
 assert sent and p.wait(timeout=2)==0 and b'RETURNED' in data,(mode,data)
 os.close(master)
 if mode=='color':
  for label,color in [('信息',96),('成功',92),('OK',92),('警告',93),('错误',91)]:
   assert ('\x1b[%sm[%s]'%(color,label)).encode() in data,(mode,label,data)
 else:assert b'\x1b[' not in data,(mode,data)
print('PASS real PTY bright labels, NO_COLOR/dumb and single-key return')
PY
[[ $? == 0 ]] || fail 'PTY UI checks'
printf 'PASS labels stderr-only, redirected pause preserves command input\n'

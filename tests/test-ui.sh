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
 cmd=r'source "$1/lib/common.sh"; source "$1/lib/platform.sh"; source "$1/lib/protocol.sh"; xm_ui_init; xm_info info; xm_success success; xm_ok ok; xm_warning warning; xm_error error; protocol_validate_node "{}"; printf "human(\"错误\", \"platform-color\")\n" | _platform_python; source <(sed -n "/^xray_boot_message()/,/^xray_boot_info()/p" "$1/install.sh"); xray_boot_error bootstrap-color; xm_pause; printf "RETURNED\\n" >&2'
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
  for label,color,body in [('信息','38;2;0;255;255','info'),('成功','38;2;0;255;0','success'),('OK','38;2;0;255;0','ok'),('警告','38;2;0;191;255','warning'),('错误','38;2;255;0;0','error')]:
   assert ('\x1b[%sm[%s] %s\x1b[0m'%(color,label,body)).encode() in data,(mode,label,data)
  assert '\x1b[38;2;255;0;0m[错误] bootstrap-color\x1b[0m'.encode() in data,data
  assert '\x1b[38;2;255;0;0m[错误] platform-color\x1b[0m'.encode() in data,data
  assert '\x1b[38;2;255;0;0m[错误] 协议：'.encode() in data,data
  import re
  assert set(re.findall(rb'\x1b\[([^m]+)m',data)) <= {b'38;2;0;191;255',b'38;2;0;255;255',b'38;2;0;255;0',b'38;2;255;0;0',b'0'},data
 else:assert b'\x1b[' not in data,(mode,data)
print('PASS real PTY bright labels, NO_COLOR/dumb and single-key return')
PY
[[ $? == 0 ]] || fail 'PTY UI checks'
printf 'PASS labels stderr-only, redirected pause preserves command input\n'

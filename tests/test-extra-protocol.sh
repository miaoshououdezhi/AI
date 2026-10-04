#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/lib/protocol.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
reject() { if "$@" >/dev/null 2>&1; then printf 'FAIL invalid input accepted\n' >&2; exit 1; fi; }
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$scratch/key.pem" -out "$scratch/cert.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' -days 2 >/dev/null 2>&1
chmod 600 "$scratch/key.pem"
protocol_new vless-ws ws 'WS # / ?' 25001 127.0.0.1 localhost /xm-ws "$scratch/cert.pem" "$scratch/key.pem" > "$scratch/ws.json"
protocol_new socks5 socks 'SOCKS' 25002 127.0.0.1 > "$scratch/socks.json"
for type in anytls hysteria2 tuicv5; do
    case "$type" in anytls) port=25003;; hysteria2) port=25004;; tuicv5) port=25005;; esac
    protocol_new "$type" "$type" "$type" "$port" 127.0.0.1 localhost "$scratch/cert.pem" "$scratch/key.pem" > "$scratch/$type.json"
done
reject protocol_tls_read "$scratch/cert.pem" "$scratch/key.pem" wrong.example
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$scratch/wrong-key.pem" -out "$scratch/wrong-cert.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost' -days 2 >/dev/null 2>&1
chmod 600 "$scratch/wrong-key.pem"
reject protocol_tls_read "$scratch/cert.pem" "$scratch/wrong-key.pem" localhost
ln -s "$scratch/key.pem" "$scratch/link.pem"
reject protocol_tls_read "$scratch/cert.pem" "$scratch/link.pem" localhost
chmod 644 "$scratch/key.pem"
reject protocol_tls_read "$scratch/cert.pem" "$scratch/key.pem" localhost
chmod 600 "$scratch/key.pem"
reject protocol_validate_node "$(jq '.uuid="bad"' "$scratch/ws.json")"
reject protocol_validate_node "$(jq '.path="/bad?x"' "$scratch/ws.json")"
reject protocol_validate_node "$(jq '.username=""' "$scratch/socks.json")"
reject protocol_validate_node "$(jq '.password="short"' "$scratch/anytls.json")"
reject protocol_validate_node "$(jq '.tls_key="not pem"' "$scratch/anytls.json")"
reject protocol_validate_node "$(jq '.sni="invalid.example"' "$scratch/tuicv5.json")"
# Explicit maintenance skips only certificate time checks, preserving identity.
mkdir "$scratch/ca-new"
: > "$scratch/ca-index"
printf '01\n' > "$scratch/ca-serial"
cat > "$scratch/ca.cnf" <<EOF
[ ca ]
default_ca = local
[ local ]
database = $scratch/ca-index
serial = $scratch/ca-serial
new_certs_dir = $scratch/ca-new
default_md = sha256
default_days = 2
policy = policy
x509_extensions = ext
[ policy ]
commonName = supplied
[ ext ]
subjectAltName = DNS:localhost,IP:127.0.0.1
EOF
openssl req -new -key "$scratch/key.pem" -out "$scratch/request.pem" -subj /CN=localhost >/dev/null 2>&1
openssl ca -batch -selfsign -config "$scratch/ca.cnf" -keyfile "$scratch/key.pem" -in "$scratch/request.pem" -startdate 20200101000000Z -enddate 20210101000000Z -out "$scratch/expired.pem" -notext >/dev/null 2>&1
jq --rawfile cert "$scratch/expired.pem" '.tls_cert=$cert' "$scratch/anytls.json" > "$scratch/expired.json"
reject protocol_validate_node "$(cat "$scratch/expired.json")"
protocol_validate_node "$(cat "$scratch/expired.json")" maintenance
reject protocol_validate_node "$(cat "$scratch/expired.json")" invalidmode
reject protocol_validate_node "$(jq '.sni="bad.example"' "$scratch/expired.json")" maintenance
reject protocol_validate_node "$(jq '.tls_key="invalid"' "$scratch/expired.json")" maintenance
reject protocol_tls_read "$scratch/expired.pem" "$scratch/key.pem" localhost
# Future leaf with matching key and SAN is also maintenance-readable only.
: > "$scratch/ca-index"
openssl ca -batch -selfsign -config "$scratch/ca.cnf" -keyfile "$scratch/key.pem" -in "$scratch/request.pem" -startdate 20900101000000Z -enddate 20910101000000Z -out "$scratch/future.pem" -notext >/dev/null 2>&1
jq --rawfile cert "$scratch/future.pem" '.tls_cert=$cert' "$scratch/anytls.json" > "$scratch/future.json"
reject protocol_validate_node "$(cat "$scratch/future.json")"
protocol_validate_node "$(cat "$scratch/future.json")" maintenance
# Two existing expired nodes can be generated only in explicit maintenance.
jq -n --slurpfile n "$scratch/expired.json" '{schema_version:1,nodes:[$n[0],($n[0]|.id="another"|.name="another"|.port=25006)]}' > "$scratch/expired-state.json"
reject protocol_generate "$scratch/expired-state.json" "$scratch/expired-xray.json"
reject protocol_generate_extra "$scratch/expired-state.json" "$scratch/expired-extra.json"
protocol_generate "$scratch/expired-state.json" "$scratch/expired-xray.json" maintenance
protocol_generate_extra "$scratch/expired-state.json" "$scratch/expired-extra.json" maintenance
reject protocol_generate "$scratch/expired-state.json" "$scratch/invalid.json" invalidmode
reject protocol_generate_extra "$scratch/expired-state.json" "$scratch/invalid.json" invalidmode
jq '.nodes[1].sni="bad.example"' "$scratch/expired-state.json" > "$scratch/invalid-state.json"
reject protocol_generate "$scratch/invalid-state.json" "$scratch/invalid.json" maintenance
reject protocol_generate_extra "$scratch/invalid-state.json" "$scratch/invalid.json" maintenance
printf 'PASS strict rejects expired/future TLS; explicit maintenance retains SAN/key validation and multi-node generation\n'
for type in ws socks anytls hysteria2 tuicv5; do
    protocol_share "$(cat "$scratch/$type.json")" > "$scratch/$type.uri"
done
"${XM_PYTHON:-python3}" - "$scratch" <<'PY'
import json,pathlib,sys,urllib.parse
p=pathlib.Path(sys.argv[1])
for t in ('ws','socks','anytls','hysteria2','tuicv5'):
 n=json.loads((p/(t+'.json')).read_text()); raw=(p/(t+'.uri')).read_text();u=urllib.parse.urlsplit(raw.strip());q=urllib.parse.parse_qs(u.query)
 assert u.hostname==n['address'] and u.port==n['port'] and urllib.parse.unquote(u.fragment)==n['name']
 assert 'insecure' not in raw and 'skip-cert-verify' not in raw and 'PRIVATE KEY' not in raw
 if t!='socks': assert q['sni']==[n['sni']]
PY
jq -s '{schema_version:1,nodes:.}' "$scratch/ws.json" "$scratch/socks.json" "$scratch/anytls.json" "$scratch/hysteria2.json" "$scratch/tuicv5.json" > "$scratch/state.json"
protocol_generate "$scratch/state.json" "$scratch/xray.json"
protocol_generate_extra "$scratch/state.json" "$scratch/extra.json"
jq -e '.inbounds|length==2' "$scratch/xray.json" >/dev/null
jq -e '(.inbounds|length==3) and .route.rules[0].ip_is_private' "$scratch/extra.json" >/dev/null
protocol_has_extra "$scratch/state.json"
[[ $(protocol_engine vless-ws) == xray && $(protocol_engine anytls) == extra ]]
# Embedded PEM migration survives deletion of original source files.
rm "$scratch/cert.pem" "$scratch/key.pem"
protocol_generate "$scratch/state.json" "$scratch/migrated-xray.json"
protocol_generate_extra "$scratch/state.json" "$scratch/migrated-extra.json"
if [[ -n ${XRAY_BIN:-} ]]; then "$XRAY_BIN" run -test -config "$scratch/xray.json"; fi
if [[ -n ${XM_EXTRA_BIN:-} ]]; then "$XM_EXTRA_BIN" check -c "$scratch/extra.json"; fi
printf 'PASS five new node schemas, TLS SAN/pair/permissions/portable PEM, URI safety, split engines\n'

# Real Python errors inherit only Common-selected safe stderr red; no machine
# stdout pollution, NO_COLOR (including empty) and TERM=dumb stay plain.
"${XM_PYTHON:-python3}" - "$repo" <<'PYTEST'
import errno,os,pty,select,subprocess,sys
repo=sys.argv[1]
commands=["protocol_validate_node '{}'", "protocol_tls_read /nonexistent-fixture-cert /nonexistent-fixture-key localhost"]
for command in commands:
 for setting in ('color','no-color','dumb','pipe'):
  env=dict(os.environ);env.pop('NO_COLOR',None);env['TERM']='dumb' if setting=='dumb' else 'xterm'
  if setting=='no-color':env['NO_COLOR']=''
  master,slave=pty.openpty()
  proc=subprocess.Popen(['bash','-c','source "$1/lib/common.sh"; xm_ui_init; source "$1/lib/protocol.sh"; '+command,'_',repo],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE if setting=='pipe' else slave,env=env)
  out,err=proc.communicate();assert proc.returncode==1 and out==b''
  if setting!='pipe':
   chunks=[]
   while select.select([master],[],[],0.1)[0]:
    try:
     data=os.read(master,4096)
     if not data:break
     chunks.append(data)
    except OSError as e:
     if e.errno==errno.EIO:break
     raise
   err=b''.join(chunks)
  os.close(slave);os.close(master)
  assert b'[\xe9\x94\x99\xe8\xaf\xaf]' in err,(command,setting,err)
  assert (b'\x1b[38;2;255;0;0m' in err)==(setting=='color'),(setting,err)
  assert b'PRIVATE KEY' not in err
print('PASS Common-selected TTY red validation/TLS errors; NO_COLOR/dumb/piped stderr plain, stdout empty')
PYTEST

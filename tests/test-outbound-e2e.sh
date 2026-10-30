#!/usr/bin/env bash
# Actual loopback chains: authenticated entry -> SS128/SS256/REALITY -> HTTP.
# Only test copies gain an exact loopback destination exception. Product private
# network blocking remains unchanged. All processes and credentials are temporary.
set -Eeuo pipefail
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
source "$repo/lib/protocol.sh"
: "${XRAY_BIN:?set XRAY_BIN}"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
export OUTBOUND_E2E_BASH=$BASH
protocol_new socks5 entry 'Entry' 24441 127.0.0.1 > "$scratch/entry.json"
protocol_new socks5 direct 'Unrelated direct node' 24442 127.0.0.1 > "$scratch/direct.json"
for bits in 128 256; do
    protocol_new shadowsocks upstream "SS$bits" 24443 127.0.0.1 '' "2022-blake3-aes-$bits-gcm" > "$scratch/ss$bits.json"
done
protocol_new vless-reality upstream 'REALITY upstream' 24443 127.0.0.1 localhost 127.0.0.1:24444 > "$scratch/reality.json"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$scratch/key.pem" -out "$scratch/cert.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost' -days 2 >/dev/null 2>&1
chmod 600 "$scratch/key.pem"
"${XM_PYTHON:-python3}" - "$repo" "$scratch" "$XRAY_BIN" <<'PY'
import http.server,json,os,pathlib,socket,struct,subprocess,sys,threading,time
repo,p,core=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]),sys.argv[3]
bash=os.environ['OUTBOUND_E2E_BASH']; payload=b'xray-manager-upstream-chain\n'
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200);self.send_header('Content-Length',str(len(payload)));self.end_headers();self.wfile.write(payload)
 def log_message(self,*args):pass
fixture=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=fixture.serve_forever,daemon=True).start();target=fixture.server_port
# A local TLS1.3/H2 camouflage endpoint removes Internet/SNI availability from
# the REALITY test. The authenticated REALITY client uses the generated key.
procs=[];logs=[]
def newport():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
tlsport=newport()
camolog=open(p/'camouflage.log','wb');logs.append(camolog)
camoconfig=p/'camouflage.json'
camoconfig.write_text(json.dumps({'log':{'loglevel':'warning'},'inbounds':[{'listen':'127.0.0.1','port':tlsport,'protocol':'dokodemo-door','settings':{'address':'127.0.0.1','port':target,'network':'tcp'},'streamSettings':{'network':'raw','security':'tls','tlsSettings':{'minVersion':'1.3','alpn':['h2'],'certificates':[{'certificateFile':str(p/'cert.pem'),'keyFile':str(p/'key.pem')}]}}}],'outbounds':[{'protocol':'freedom','settings':{'finalRules':[{'action':'allow','ip':['127.0.0.1/32'],'port':str(target)}]}}]}))
camouflage=subprocess.Popen([core,'run','-config',str(camoconfig)],stdout=camolog,stderr=camolog)
procs.append(camouflage)
def write(name,value):
 path=p/name;path.write_text(json.dumps(value));path.chmod(0o600);return path
def generate(state,name):
 source=write(name+'-state.json',state);dest=p/(name+'.json')
 subprocess.run([bash,'-c','source "$1/lib/protocol.sh"; protocol_generate "$2" "$3"','_',str(repo),str(source),str(dest)],check=True,stdout=subprocess.DEVNULL)
 return json.loads(dest.read_text())
def share(node):
 source=write('share-node.json',node)
 return subprocess.check_output([bash,'-c','source "$1/lib/protocol.sh"; protocol_share "$(cat "$2")"','_',str(repo),str(source)],text=True).strip()
def start(name,cfg):
 cfg['log']={'loglevel':'debug'}
 path=write(name+'.json',cfg);log=open(p/(name+'.log'),'wb');logs.append(log)
 r=subprocess.run([core,'run','-test','-config',str(path)],stdout=log,stderr=log)
 assert r.returncode==0,name+' native validation failed'
 proc=subprocess.Popen([core,'run','-config',str(path)],stdout=log,stderr=log);procs.append(proc)
 return proc
def stop(proc):
 if proc.poll() is None:
  proc.terminate()
  try:proc.wait(timeout=5)
  except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=5)
def ready(port,proc):
 for _ in range(60):
  assert proc.poll() is None,'test core exited'
  try:
   with socket.create_connection(('127.0.0.1',port),timeout=.15):return
  except OSError:time.sleep(.05)
 raise AssertionError('test listener did not start')
def readexact(s,n):
 data=b''
 while len(data)<n:
  part=s.recv(n-len(data))
  if not part:raise OSError('early proxy close')
  data+=part
 return data
def request(node):
 with socket.create_connection(('127.0.0.1',node['port']),timeout=2) as s:
  s.settimeout(4);s.sendall(b'\x05\x01\x02');assert readexact(s,2)==b'\x05\x02'
  user=node['username'].encode();password=node['password'].encode();s.sendall(b'\x01'+bytes([len(user)])+user+bytes([len(password)])+password);assert readexact(s,2)==b'\x01\x00'
  s.sendall(b'\x05\x01\x00\x01'+socket.inet_aton('127.0.0.1')+struct.pack('!H',target))
  answer=readexact(s,4)
  if answer[1]:raise OSError('upstream refused')
  if answer[3]==1:readexact(s,6)
  elif answer[3]==4:readexact(s,18)
  else:readexact(s,readexact(s,1)[0]+2)
  s.sendall(b'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n');data=b''
  while True:
   block=s.recv(4096)
   if not block:break
   data+=block
  if data.split(b'\r\n\r\n',1)[-1]!=payload:raise OSError('wrong fixture response')
def fixture_allow(config,bindings):
 # Preserve the product block rule and all per-node routes, adding only exact
 # fixture destination exceptions. Binding names come from generated routes.
 exceptions=[{'type':'field','inboundTag':[tag],'ip':['127.0.0.1/32'],'port':str(target),'outboundTag':out} for tag,out in bindings]
 config['routing']['rules']=exceptions+config['routing']['rules']
 for out in config['outbounds']:
  if out['protocol']=='freedom':out['settings']={'finalRules':[{'action':'allow','ip':['127.0.0.1/32'],'port':str(target)}]}
 for inbound in config['inbounds']:inbound['listen']='127.0.0.1'
 return config
try:
 ready(tlsport,camouflage)
 for variant in ('ss128','ss256','reality'):
  upstream=json.loads((p/(variant+'.json')).read_text());upstream['port']=newport()
  if variant=='reality':upstream['target']='127.0.0.1:'+str(tlsport)
  uri=share(upstream)
  entry=json.loads((p/'entry.json').read_text());entry['port']=newport();entry['outbound_route']={'uri':uri,'mode':'all','domains':[],'ips':[]}
  direct=json.loads((p/'direct.json').read_text());direct['port']=newport()
  upcfg=generate({'schema_version':1,'nodes':[upstream]},variant+'-upstream')
  relay=generate({'schema_version':1,'nodes':[entry,direct]},variant+'-relay')
  bound=[r for r in relay['routing']['rules'] if r.get('inboundTag')==['node-entry']]
  assert len(bound)==1 and bound[0]['outboundTag']=='outbound-entry'
  assert not any(r.get('inboundTag')==['node-direct'] for r in relay['routing']['rules'])
  assert relay['routing']['rules'][0]['outboundTag']=='block'
  up=start(variant+'-up',fixture_allow(upcfg,[('node-upstream','direct')]))
  middle=start(variant+'-middle',fixture_allow(relay,[('node-entry',bound[0]['outboundTag']),('node-direct','direct')]))
  ready(upstream['port'],up);ready(entry['port'],middle)
  request(entry);request(direct)
  # An upstream outage must fail the routed node while the unrelated direct
  # node still succeeds, proving this was a real chain, not silent fallback.
  stop(up)
  try:request(entry)
  except (OSError,AssertionError):pass
  else:raise AssertionError('routed node silently bypassed stopped upstream')
  request(direct);stop(middle)
  # Removing the route restores only this node to direct connectivity.
  del entry['outbound_route'];restored=generate({'schema_version':1,'nodes':[entry,direct]},variant+'-restored')
  assert len(restored['outbounds'])==2
  middle=start(variant+'-restored-run',fixture_allow(restored,[('node-entry','direct'),('node-direct','direct')]))
  ready(entry['port'],middle);request(entry);stop(middle)
  print('PASS actual '+variant+' upstream chain, node isolation, no fallback on outage and direct restoration')
except Exception:
 for log in logs:log.flush()
 for path in p.glob('*.log'):
  print(path.name+': '+path.read_text(errors='replace')[-6000:],file=sys.stderr)
 raise
finally:
 for proc in reversed(procs):stop(proc)
 for log in logs:log.close()
 fixture.shutdown();fixture.server_close()
PY

"""Real AppStore, SQLite and direct downloads against private loopback fixtures."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from collections import Counter
import json
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'work/runtime-optimization-2026-10-15'
WORK.mkdir(parents=True, exist_ok=True)
counts = Counter()
state = {'fault': '', 'download_delay': .8}
lock = threading.Lock()
CONTENT = "proxies: []\nproxy-groups: []\nrules: ['MATCH,DIRECT']\n"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        path = self.path
        if path.startswith('/control/'):
            with lock: state['fault'] = path.split('/')[-1]
            body = b'{}'
        elif path == '/stats':
            with lock: body = json.dumps(dict(counts)).encode()
        else:
            with lock:
                counts[path] += 1
                fault = state['fault']
                if fault == 'version-once' and path == '/version': state['fault'] = ''
            if path == '/subscription':
                time.sleep(state['download_delay'])
                body = CONTENT.encode()
            else:
                time.sleep(.01)
                bodies = {
                    '/version': {'version':'fixture'},
                    '/proxies': {'proxies':{'DIRECT':{'name':'DIRECT','type':'Direct'}}},
                    '/providers/proxies': {'providers':{}},
                    '/connections': {'uploadTotal':1,'downloadTotal':2,'connections':[{'id':'retained','metadata':{'process':'fixture','processPath':'/fixture'},'upload':1,'download':2}]},
                    '/rules': {'rules':[]},
                    '/traffic': {'up':23,'down':42},
                    '/logs': {'type':'info','payload':'stream-fixture'},
                }
                body = json.dumps(bodies.get(path,{})).encode()
                if path in ['/traffic','/logs']: body += b'\n'
                if (path == '/version' and fault in ['version-once','version-all']) or fault == path[1:]:
                    self.send_response(503)
                    self.send_header('Content-Length','0'); self.end_headers(); return
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(body)))
        if path == '/subscription': self.send_header('subscription-userinfo','upload=1; download=2; total=1024')
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass

server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
products = ROOT / '.build/out/Products/Release'
binary = WORK / 'runtime-check'
command = ['xcrun','swiftc','-O','-g','-parse-as-library','-target','arm64-apple-macosx14.0','-sdk','/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk','-I',str(products),'-I',str(ROOT/'.build/checkouts/Yams/Sources/CYaml/include')]
command += [str(ROOT / name) for name in ['script/check_runtime_resilience.swift','Sources/LumaRoute/Stores/AppStore.swift','Sources/LumaRoute/Stores/RuleSubscriptionStore.swift','Sources/LumaRoute/Stores/RuntimeData.swift','Sources/LumaRoute/Support/HelperClient.swift']]
command += [str(products/name) for name in ['LumaRouteCore.o','Yams.o','CYaml.o']]
command += ['-o',str(binary)]
subprocess.run(command,cwd=ROOT,check=True)
try:
    runroot = WORK / ('data-'+str(time.time_ns()))
    result = subprocess.run([str(binary),str(server.server_port),str(runroot)],cwd=ROOT,timeout=90,capture_output=True,text=True)
    print(result.stdout, end='')
    if result.returncode: print(result.stderr)
    (WORK/'resilience.log').write_text(result.stdout+result.stderr)
    (WORK/'requests.json').write_text(json.dumps(dict(counts),indent=2))
    raise SystemExit(result.returncode)
finally: server.shutdown()

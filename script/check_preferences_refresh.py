"""Measure real AppStore request counts against a private loopback fixture."""
from build_environment import configure
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from collections import Counter
import json
import subprocess
import threading
import time
import sys

SDK = configure()

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'work/preferences-refresh-2026-10-15'
WORK.mkdir(parents=True, exist_ok=True)
# --baseline is for compiling against the pre-optimization AppStore source.
optimized = '--baseline' not in sys.argv
counts = Counter()
polling = {}
stages = {}
lock = threading.Lock()
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        if self.path.startswith('/checkpoint/'):
            name = self.path.split('/')[-1]
            if name == 'hidden': polling.update(counts)
            if name != 'discard': stages[name] = dict(counts)
            body = json.dumps(dict(counts)).encode()
            counts.clear()
            self.send_response(200)
            self.send_header('Content-Length',str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        with lock: counts[self.path] += 1
        time.sleep(.02)
        bodies = {
            '/version': {'version':'fixture'},
            '/proxies': {'proxies':{'group':{'name':'group','type':'Selector','now':'provider-node','all':['provider-node']},'provider-node':{'name':'provider-node','type':'Shadowsocks','history':[{'time':'fixture','delay':42}]}}},
            '/providers/proxies': {'providers':{'fixture-provider':{'name':'fixture-provider','vehicleType':'HTTP','proxies':[{'name':'provider-node','type':'Shadowsocks'}]}}},
            '/connections': {'uploadTotal':0,'downloadTotal':0,'connections':[{'id':'fixture','upload':0,'download':0,'metadata':{'process':'fixture','processPath':'/fixture'}}]},
            '/rules': {'rules':[{'type':'Match','payload':'','proxy':'group'}]},
        }
        body = json.dumps(bodies[self.path]).encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        self.wfile.write(body)
server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
products = ROOT / '.build/out/Products/Release'
binary = WORK / ('after-check' if optimized else 'before-check')
command = ['xcrun','swiftc','-O','-parse-as-library','-target','arm64-apple-macosx14.0','-sdk',SDK,'-I',str(products),'-I',str(ROOT/'.build/checkouts/Yams/Sources/CYaml/include')]
if optimized: command += ['-D','OPTIMIZED']
command += [str(ROOT / name) for name in ['script/check_preferences_refresh.swift','Sources/LumaRoute/Stores/AppStore.swift','Sources/LumaRoute/Stores/RuleSubscriptionStore.swift','Sources/LumaRoute/Stores/RuntimeData.swift','Sources/LumaRoute/Support/HelperClient.swift']]
command += [str(products/name) for name in ['LumaRouteCore.o','Yams.o','CYaml.o']]
command += ['-o',str(binary)]
subprocess.run(command,cwd=ROOT,check=True)
try:
    runroot = WORK / ('after-data-'+str(time.time_ns()) if optimized else 'before-data-'+str(time.time_ns()))
    began = time.monotonic()
    result = subprocess.run([str(binary),str(server.server_port),str(runroot)],cwd=ROOT,timeout=60,capture_output=True,text=True)
    print(result.stdout)
    if result.returncode:
        print(result.stderr)
        raise SystemExit(result.returncode)
    report = {'counts':dict(polling or counts),'total':sum((polling or counts).values()),'stages':stages,'elapsed':round(time.monotonic()-began,3)}
    # Polling-only counts are emitted by the Swift process before other tests below.
    print(json.dumps(report))
    (WORK/('after-fixture.json' if optimized else 'before-fixture.json')).write_text(json.dumps(report,indent=2))
    if optimized:
        assert polling == {'/version':30,'/proxies':6,'/providers/proxies':2}, polling
        assert stages['0'] == {'/version':30,'/proxies':30,'/providers/proxies':2}, stages['0']
        assert stages['1'] == {'/version':30,'/proxies':6,'/providers/proxies':2,'/connections':30}, stages['1']
        assert stages['2'] == {'/version':30,'/proxies':6,'/providers/proxies':2,'/rules':2}, stages['2']
finally: server.shutdown()

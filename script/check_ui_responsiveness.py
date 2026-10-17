"""Isolated native UI/refresh acceptance. Never bootstraps or changes the live service.

Requires private input.sqlite and proxies.json under work/ui-optimization-2026-10-15.
Use --baseline to compile the frozen source snapshot, --interactive for CUA checks.
"""
from build_environment import configure
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from collections import Counter
import json, plistlib, subprocess, sys, threading, time
SDK = configure()

ROOT=Path(__file__).resolve().parents[1]
WORK=ROOT/'work/ui-optimization-2026-10-15'
WORK.mkdir(parents=True,exist_ok=True,mode=0o700)
baseline='--baseline' in sys.argv
interactive='--interactive' in sys.argv
run_only='--run-only' in sys.argv
label='before' if baseline else 'after'
sources=WORK/'before-sources/LumaRoute' if baseline else ROOT/'Sources/LumaRoute'
products=ROOT/'.build/out/Products/Release'
counts=Counter()
class Fixture(BaseHTTPRequestHandler):
 def log_message(self,*_):pass
 def do_GET(self):
  if self.path=='/counts': result=dict(counts)
  elif self.path=='/reset': result=dict(counts);counts.clear()
  else:
   counts[self.path]+=1
   result={'/version':{'version':'fixture'},'/proxies':{'proxies':{'group':{'name':'group','type':'Selector','now':'node','all':['node']},'node':{'name':'node','type':'Shadowsocks'}}},'/providers/proxies':{'providers':{}},'/connections':{'connections':[]},'/rules':{'rules':[]}}[self.path]
  payload=json.dumps(result).encode();self.send_response(200);self.send_header('Content-Length',str(len(payload)));self.end_headers();self.wfile.write(payload)
server=ThreadingHTTPServer(('127.0.0.1',0),Fixture)
threading.Thread(target=server.serve_forever,daemon=True).start()
app=WORK/(('UIBaseline' if baseline else 'UIOptimized')+'.app')
(app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
menu=WORK/(label+'-Menu.swift')
menu.write_text((sources/'App/StatusMenuController.swift').read_text()+'''\nextension StatusMenuController {
 func checkMenu() -> NSMenu { menuNeedsUpdate(menu); return menu }
 func checkTracking(_ opened:Bool) { if opened { menuWillOpen(menu) } else { menuDidClose(menu) } }
 func showForQA(_ view:NSView) { menu.popUp(positioning:nil,at:NSPoint(x:20,y:view.bounds.height-20),in:view) }
}\n''')
command=['xcrun','swiftc','-O','-parse-as-library','-target','arm64-apple-macosx14.0','-sdk',SDK,'-I',str(products),'-I',str(ROOT/'.build/checkouts/Yams/Sources/CYaml/include')]
if not baseline:command+=['-D','UI_OPTIMIZED']
command += [str(ROOT/'script/check_ui_responsiveness.swift'),str(menu),str(sources/'App/MenuBarRateLayout.swift')]
for folder in ['Views','Stores','Support']:command += [str(p) for p in (sources/folder).glob('*.swift')]
command += [str(products/n) for n in ['LumaRouteCore.o','Yams.o','CYaml.o']]
command += ['-o',str(app/'Contents/MacOS/UIResponseCheck')]
if not run_only:subprocess.run(command,cwd=ROOT,check=True)
with (app/'Contents/Info.plist').open('wb') as f:plistlib.dump({'CFBundleIdentifier':'app.lumaroute.ui-response-'+label,'CFBundleExecutable':'UIResponseCheck','CFBundleName':'UIResponseCheck','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'14.0','NSPrincipalClass':'NSApplication','LSUIElement':not interactive},f)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
report=WORK/(label+'-response.json')
if report.exists():report.unlink()
args=[str(WORK),label,str(server.server_port),'interactive' if interactive else 'automatic']
subprocess.run(['open','-n',str(app),'--args',*args],check=True)
if interactive:
 print('Interactive host:',app,flush=True)
 while not (WORK/'close-interactive').exists():time.sleep(.25)
else:
 deadline=time.monotonic()+90
 while not report.exists() and time.monotonic()<deadline:time.sleep(.1)
 if not report.exists():raise RuntimeError('Native host did not finish; inspect private failure output')
 result=json.loads(report.read_text());print(json.dumps(result,ensure_ascii=False,indent=2))
 if not baseline and result.get('failures'):raise RuntimeError('UI regression failed')
server.shutdown()

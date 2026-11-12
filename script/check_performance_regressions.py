"""Exercise real pages/tables/menus with synthetic state; never bootstrap or use XPC.

Counts expensive operations in generated source copies, without timing thresholds.
--baseline REF compiles the historical UI against the supplied core products.
"""
from pathlib import Path
import argparse,json,os,plistlib,signal,subprocess
from build_environment import configure

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--products',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--baseline')
p.add_argument('--skip-build',action='store_true')
p.add_argument('--interactive',action='store_true',help='Leave an isolated menu host open for manual verification')
a=p.parse_args();sdk=configure();w=a.output.resolve();w.mkdir(parents=True,exist_ok=True)
products=a.products.resolve();build=products.parent.parent
sources=[]
for folder in ['Views','Stores','Support','App']:
    for original in sorted((ROOT/'Sources/LumaRoute'/folder).glob('*.swift')):
        if original.name in ['LumaRouteApp.swift','AppUpdater.swift']:continue
        s=subprocess.check_output(['git','show',a.baseline+':'+str(original.relative_to(ROOT))],cwd=ROOT,text=True) if a.baseline else original.read_text()
        if original.name=='ConnectionsPage.swift':
            s=s.replace('var items:[LiveConnection] {\n        ','var items:[LiveConnection] {\n        Probe.connectionFilters += 1\n        return ',1)
        elif original.name=='LogsPage.swift':
            s=s.replace('var items:[LogEntry] {','var items:[LogEntry] {\n        Probe.logFilters += 1',1)
        elif original.name=='ConnectionTableView.swift':
            s=s.replace('table.reloadData()','Probe.connectionReloads += 1; table.reloadData()')
        elif original.name=='StatusMenuController.swift':
            s=s.replace('update(store)','Probe.menuUpdates += 1; update(store)')
            s+='''\nextension StatusMenuController {
 func testMenu()->NSMenu { menuNeedsUpdate(menu);return menu }
 func testShow(at view:NSView){menu.popUp(positioning:nil,at:NSPoint(x:20,y:view.bounds.height-20),in:view)}
 func testTick(){refreshMenuState()}
 var testTimerRunning:Bool {trackingTimer != nil}
 func testDispose(){trackingTimer?.invalidate();NSStatusBar.system.removeStatusItem(statusItem)}
}\n'''
        generated=w/original.name;generated.write_text(s);sources.append(str(generated))
app=w/'PerformanceRegression.app';binary=app/'Contents/MacOS/PerformanceRegression';binary.parent.mkdir(parents=True,exist_ok=True)
cmd=['xcrun','swiftc','-O','-whole-module-optimization','-parse-as-library','-swift-version','6','-warnings-as-errors','-sdk',sdk,'-target','arm64-apple-macosx14.0','-I',str(products/'Modules'),'-I',str(build/'checkouts/Yams/Sources/CYaml/include'),str(ROOT/'script/check_performance_regressions.swift'),*sources]
cmd += [str(o) for name in ['LumaRouteCore','Yams','CYaml'] for o in sorted((products/(name+'.build')).rglob('*.o'))]
if not a.skip_build:subprocess.run(cmd+['-o',str(binary)],check=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='app.lumaroute.performance-regression',CFBundleExecutable='PerformanceRegression',CFBundleName='PerformanceRegression',CFBundlePackageType='APPL',LSUIElement=True,LSMinimumSystemVersion='14.0',NSPrincipalClass='NSApplication')))
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
report=w/'result.json';report.unlink(missing_ok=True);stderr=w/'stderr.log'
progress=w/'progress.json';progress.unlink(missing_ok=True)
if a.interactive:
    subprocess.run(['open','-n',str(app),'--stderr',str(stderr),'--args',str(w),'interactive'],check=True)
    print('Isolated menu host:',app)
    raise SystemExit()
try:
    subprocess.run(['open','-W','-n',str(app),'--stderr',str(stderr),'--args',str(w)],check=True,timeout=120)
finally:
    if progress.exists():
        pid=json.loads(progress.read_text())['pid']
        identity=subprocess.run(['ps','-p',str(pid),'-o','comm='],capture_output=True,text=True)
        if identity.stdout.strip()==str(binary):
            try:os.kill(pid,signal.SIGTERM)
            except ProcessLookupError:pass
r=json.loads(report.read_text())
if 'reentrant operation in its NSTableView delegate' in stderr.read_text(errors='replace'):r['failures'].append('AppKit table reentrancy warning')
print(json.dumps(r,ensure_ascii=False,indent=2))
if r['failures']:raise SystemExit(1)

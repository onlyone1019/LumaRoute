"""Regression for real log page navigation, updates, selection and table warnings.

Build native dependencies first. Uses synthetic logs and private SQLite only;
never starts a core/helper or reads the installed application's data.
"""
from pathlib import Path
import argparse,json,os,plistlib,platform,signal,subprocess,tempfile,fcntl,hashlib
from build_environment import configure
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--products',type=Path)
p.add_argument('--source-root',type=Path,default=ROOT,help='Repository root, or a snapshot containing Views/Stores/Support/App')
p.add_argument('--output',type=Path)
p.add_argument('--prepare-only',action='store_true',help='Build signed fixture without launching, for Instruments')
p.add_argument('--skip-build',action='store_true')
a=p.parse_args()
if a.skip_build and not a.output:p.error('--skip-build requires --output')
sdk=configure();arch=platform.machine()
products=(a.products or ROOT/f'.build/{arch}-apple-macosx/release').resolve()
arch=subprocess.check_output(['lipo','-archs',str(products/'LumaRoute')],text=True).strip()
if arch not in ['arm64','x86_64']:raise ValueError('Requires single-architecture native products')
source=a.source_root.resolve()
if (source/'Sources/LumaRoute').exists():source=source/'Sources/LumaRoute'
w=a.output.resolve() if a.output else Path(tempfile.mkdtemp(prefix='lumaroute-logs-gui-'))
w.mkdir(parents=True,exist_ok=True)
run_lock=(w/'run.lock').open('w');fcntl.flock(run_lock,fcntl.LOCK_EX)
name='LogsCheck-'+hashlib.sha256(str(w).encode()).hexdigest()[:12]
app=w/(name+'.app');binary=app/'Contents/MacOS'/name;binary.parent.mkdir(parents=True,exist_ok=True)
include=ROOT/'.build/checkouts/Yams/Sources/CYaml/include'
if not include.exists():include=ROOT/f'.build/{arch}/checkouts/Yams/Sources/CYaml/include'
cmd=['xcrun','swiftc','-O','-g','-whole-module-optimization','-parse-as-library','-swift-version','6','-warnings-as-errors','-sdk',sdk,'-target',arch+'-apple-macosx14.0','-I',str(products/'Modules'),'-I',str(include),str(ROOT/'script/check_logs_page.swift')]
cmd += [str(f) for folder in ['Views','Stores','Support','App'] for f in sorted((source/folder).glob('*.swift')) if f.name not in ['LumaRouteApp.swift','AppUpdater.swift']]
cmd += [str(f) for name in ['LumaRouteCore','Yams','CYaml'] for f in sorted((products/(name+'.build')).rglob('*.o'))]
cmd += ['-o',str(binary)]
if not a.skip_build:subprocess.run(cmd,cwd=w,check=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='app.lumaroute.logs-check.'+hashlib.sha256(str(app).encode()).hexdigest()[:16],CFBundleExecutable=name,CFBundleName=name,CFBundlePackageType='APPL',LSUIElement=True,LSMinimumSystemVersion='14.0',NSPrincipalClass='NSApplication')))
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
if a.prepare_only:print(binary);raise SystemExit()
report=w/'result.json';stderr=w/'stderr.log';report.unlink(missing_ok=True);stderr.unlink(missing_ok=True)
# open preserves the GUI login-session context used by the real application.
try:
    subprocess.run(['open','-W','-n','--arch',arch,str(app),'--stderr',str(stderr),'--args',str(w)],check=True,timeout=90)
except subprocess.TimeoutExpired:
    progress=w/'progress.json'
    if progress.exists():
        pid=json.loads(progress.read_text())['pid']
        identity=subprocess.run(['ps','-p',str(pid),'-o','comm='],capture_output=True,text=True)
        if identity.stdout.strip()==str(binary):
            try:os.kill(pid,signal.SIGTERM)
            except ProcessLookupError:pass
    raise
if not report.exists():raise RuntimeError('Fixture exited without a completed report; see '+str(stderr))
r=json.loads(report.read_text())
if Path(r['binary_path']).resolve()!=binary.resolve():raise RuntimeError('Wrong GUI fixture launched: '+r['binary_path'])
r['reentrant_warnings']=stderr.read_text(errors='replace').count('reentrant operation in its NSTableView delegate')
if r['reentrant_warnings']:r['failures'].append(f"{r['reentrant_warnings']} AppKit table reentrancy warnings")
report.write_text(json.dumps(r,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(dict(checks=len(r['checks']),failures=r['failures'],open_ms=r['open_ms'],update_total_ms=sum(r['update_ms']),reentrant_warnings=r['reentrant_warnings'],artifacts=str(w)),ensure_ascii=False,indent=2))
if r['failures']:raise SystemExit(1)

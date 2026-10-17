"""Real Sparkle install/relaunch against signed loopback fixtures.

Compiles production AppUpdater, AppDelegate and prepareAppUpdateRestart. System
network/service effects are stubbed; private SQLite and separate bundle IDs keep
this independent of the installed LumaRoute. No Release or root service is changed.
"""
from build_environment import configure
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
import importlib.util
import json
import os
import platform
import plistlib
import signal
import shutil
import sqlite3
import subprocess
import threading
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=ROOT/'work/sparkle-update')
parser.add_argument('--modes', nargs='+', default=['success', 'dismiss', 'cancel-check', 'cancel-download', 'bad-signature', 'no-update', 'stop-failure', 'wrong-architecture', 'foreign-source', 'unsigned-feed', 'download-failure', 'missing-feed'])
args = parser.parse_args()
sdk = configure()
work = args.output.resolve()
work.mkdir(parents=True, exist_ok=True)
arch = platform.machine()
products = ROOT/f'.build/{arch}-apple-macosx/release'
frameworks = ROOT/'dist/LumaRoute.app/Contents/Frameworks'
tools = ROOT/'.build/artifacts/sparkle/Sparkle/bin'
source = (ROOT/'Sources/LumaRoute/App/LumaRouteApp.swift').read_text()
delegate = source[source.index('@MainActor\nfinal class AppDelegate:'):source.index('/// Identifies only')]
(work/'AppDelegate.swift').write_text('import AppKit\nimport OSLog\n'+delegate)
store = (ROOT/'Sources/LumaRoute/Stores/AppStore.swift').read_text()
method = store[store.index('    func prepareAppUpdateRestart()'):store.index('    func shutdown()')]
(work/'PrepareUpdate.swift').write_text('import Foundation\nimport LumaRouteCore\nextension AppStore {\n'+method+'\n}\n')
binary = work/'SparkleUpdateCheck'
command = ['xcrun', 'swiftc', '-O', '-parse-as-library', '-swift-version', '6', '-sdk', sdk,
           '-target', arch+'-apple-macosx14.0', '-I', str(products/'Modules'),
           '-I', str(ROOT/'.build/checkouts/Yams/Sources/CYaml/include'),
           '-F', str(frameworks), '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
           str(ROOT/'Sources/LumaRoute/App/AppUpdater.swift'), str(ROOT/'script/check_sparkle_update.swift'),
           str(work/'AppDelegate.swift'), str(work/'PrepareUpdate.swift')]
command += [str(p) for name in ['LumaRouteCore','Yams','CYaml'] for p in (products/(name+'.build')).rglob('*.o')]
subprocess.run(command+['-o', str(binary)], check=True)
spec = importlib.util.spec_from_file_location('appcast', ROOT/'script/generate_appcast.py')
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        name = self.path.split('?',1)[0].lstrip('/')
        path = served/name
        if not path.is_file(): self.send_error(404); return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', 'application/xml' if path.suffix == '.xml' else 'application/octet-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass

server = ThreadingHTTPServer(('127.0.0.1',0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'
results = []
for mode in args.modes:
    case = work/(mode+'-'+uuid.uuid4().hex[:8])
    case.mkdir()
    served = case/'served'
    served.mkdir()
    app = case/'LumaRoute.app'
    target = case/'new/LumaRoute.app'
    bundle_id = 'app.lumaroute.sparkle-check-'+uuid.uuid4().hex
    archive = served/f'LumaRoute-9.9.1-build.1002-macos-{arch}.zip'
    for destination,build in [(app,1001),(target,1002)]:
        (destination/'Contents/MacOS').mkdir(parents=True)
        shutil.copy2(binary, destination/'Contents/MacOS/SparkleUpdateCheck')
        shutil.copytree(frameworks, destination/'Contents/Frameworks', symlinks=True)
        info = dict(CFBundleExecutable='SparkleUpdateCheck', CFBundleIdentifier=bundle_id,
                    CFBundleName='LumaRoute', CFBundlePackageType='APPL',
                    CFBundleDevelopmentRegion='zh_CN', CFBundleLocalizations=['zh_CN'],
                    CFBundleShortVersionString='9.9.0' if build == 1001 else '9.9.1', CFBundleVersion=str(build),
                    LSMinimumSystemVersion='14.0', NSPrincipalClass='NSApplication',
                    SUFeedURL=base+f'/appcast-{arch}.xml',
                    SUPublicEDKey=(ROOT/'Resources/Sparkle/public-key.txt').read_text().strip(),
                    SUEnableAutomaticChecks=False, SUAllowsAutomaticUpdates=False, SUAutomaticallyUpdate=False,
                    SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                    NSAppTransportSecurity=dict(NSAllowsLocalNetworking=True),
                    LumaRouteTestRoot=str(case), LumaRouteTestMode=mode, LumaRouteTestArchiveURL=base+'/'+archive.name)
        (destination/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign','--force','--sign','-',str(destination)], check=True, capture_output=True)
    subprocess.run(['ditto','-c','-k','--sequesterRsrc','--keepParent',str(target),str(archive)], check=True)
    if mode == 'no-update':
        # Generate a signed feed with the installed build, preserving the archive filename contract.
        same = served/f'LumaRoute-9.9.0-build.1001-macos-{arch}.zip'
        shutil.copy2(archive,same)
        feed = appcast.generate(app,same,'v9.9.0',served,tools)
    else:
        feed = appcast.generate(target,archive,'v9.9.1',served,tools)
    if mode == 'bad-signature':
        with archive.open('ab') as file: file.write(b'tampered update')
    if mode in ['wrong-architecture', 'foreign-source', 'unsigned-feed']:
        tree = ET.parse(feed)
        enclosure = tree.getroot().find('./channel/item/enclosure')
        if mode == 'wrong-architecture':
            other = 'x86_64' if arch == 'arm64' else 'arm64'
            enclosure.set('url',enclosure.get('url').replace(f'-macos-{arch}.zip',f'-macos-{other}.zip'))
        elif mode == 'foreign-source':
            enclosure.set('url',enclosure.get('url').replace('github.com','example.com'))
        tree.write(feed,encoding='utf-8',xml_declaration=True)
        if mode != 'unsigned-feed':
            subprocess.run([str(tools/'sign_update'),'--account','app.lumaroute.desktop',str(feed)],check=True,capture_output=True)
    if mode == 'download-failure':
        archive.unlink()
    if mode == 'missing-feed':
        feed.unlink()
    log = case/'stderr.log'
    launch = subprocess.Popen(['open','-W','-n',str(app),'--stderr',str(log)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    deadline = time.monotonic()+(240 if mode == 'native-ui' else 80)
    report = case/'result.json'
    while not report.exists() and time.monotonic()<deadline: time.sleep(.15)
    try:
        if not report.exists(): raise AssertionError('Timed out; inspect '+str(case))
        result = json.loads(report.read_text())
        expected = {'success':'updated-and-restored','dismiss':'dismissed','cancel-download':'download-cancelled',
                    'bad-signature':'error','no-update':'no-update','stop-failure':'termination-rejected',
                    'wrong-architecture':'error','foreign-source':'error','unsigned-feed':'error','download-failure':'error','native-ui':'updated-and-restored',
                    'cancel-check':'check-cancelled','missing-feed':'error'}[mode]
        assert result['status'] == expected, result
        if mode in ['cancel-check', 'missing-feed']:
            assert result['checking'] is False and result['updateMessage'] != '正在检查更新…', result
        if mode == 'missing-feed':
            assert result['updateMessage'] == '更新源暂不可用（尚未发布或已移除），请稍后重试', result
        installed = plistlib.loads((app/'Contents/Info.plist').read_bytes())
        assert installed['CFBundleVersion'] == ('1002' if mode in ['success','native-ui'] else '1001')
        connection = sqlite3.connect(case/'data/lumaroute.sqlite')
        assert connection.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        connection.close()
        if mode in ['success','native-ui']:
            if mode == 'success':
                assert all(event in result['events'] for event in ['check','download','ready','install','shutdown','relaunched']), result
            assert (case/'before-state.json').read_bytes() == (case/'after-state.json').read_bytes(), 'business state changed'
            assert not (case/'data/app-update-restart.json').exists(), 'restart state not consumed'
        else:
            assert not (case/'data/app-update-restart.json').exists(), 'failed update retained restart state'
        print('PASS',mode,':',result['status'],flush=True)
        results.append(dict(mode=mode,**result))
    finally:
        # Stop only processes whose executable lives inside this fixture directory.
        processes = subprocess.check_output(['ps','-axo','pid=,comm='],text=True)
        for line in processes.splitlines():
            pair=line.strip().split(None,1)
            if len(pair)==2 and pair[1].startswith(str(case)+'/'):
                try: os.kill(int(pair[0]),signal.SIGTERM)
                except ProcessLookupError: pass
        time.sleep(.5)
        processes = subprocess.check_output(['ps','-axo','pid=,comm='],text=True)
        for line in processes.splitlines():
            pair=line.strip().split(None,1)
            if len(pair)==2 and pair[1].startswith(str(case)+'/'):
                try: os.kill(int(pair[0]),signal.SIGKILL)
                except ProcessLookupError: pass
        try: launch.communicate(timeout=5)
        except subprocess.TimeoutExpired: launch.terminate(); launch.communicate(timeout=5)
server.shutdown()
report_name = 'results-native-ui.json' if args.modes == ['native-ui'] else 'results.json'
(work/report_name).write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
print('Update acceptance:',work/report_name)

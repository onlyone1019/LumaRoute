"""Verify saved node restoration through production bootstrap and real Mihomo.

Only HelperClient's discovery is disabled in a generated fixture so this test
cannot discover or access the installed administrator service. All storage and
ports belong to this temporary bundle. No system proxy or TUN is enabled.
"""
from build_environment import configure
from pathlib import Path
import json
import os
import platform
import plistlib
import shutil
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sdk = configure()
arch = platform.machine()
products = ROOT/f'.build/{arch}-apple-macosx/release'
(ROOT/'work').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='lumaroute-update-choices-',dir=ROOT/'work') as directory:
    work = Path(directory)
    helper = (ROOT/'Sources/LumaRoute/Support/HelperClient.swift').read_text()
    start = helper.index('    var localInstallation:')
    end = helper.index('    let supportsPrivilegedService:',start)
    helper = helper[:start]+'    var localInstallation:LocalServiceInstallation? { nil }\n'+helper[end:]
    start = helper.index('    let supportsPrivilegedService:')
    end = helper.index('    var label:',start)
    helper = helper[:start]+'    let supportsPrivilegedService = false\n    var status:SMAppService.Status { .notRegistered }\n'+helper[end:]
    (work/'HelperClient.swift').write_text(helper)
    app = work/'UpdateChoices.app'
    binary = app/'Contents/MacOS/UpdateChoices'
    binary.parent.mkdir(parents=True)
    resources = app/'Contents/Resources'
    resources.mkdir()
    shutil.copy2(ROOT/f'Resources/Core/mihomo-{arch}',resources/'mihomo')
    shutil.copytree(ROOT/'dist/LumaRoute.app/Contents/Resources/GeoData',resources/'GeoData')
    info = dict(CFBundleIdentifier='app.lumaroute.update-choices-check',CFBundleExecutable='UpdateChoices',
                CFBundleName='UpdateChoices',CFBundlePackageType='APPL',CFBundleShortVersionString='9.9.1',
                CFBundleVersion='1002',LumaRouteCoreVersion=json.loads((ROOT/'Resources/Core/release.json').read_text())['version'])
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    command = ['xcrun','swiftc','-O','-parse-as-library','-swift-version','6','-sdk',sdk,'-target',arch+'-apple-macosx14.0',
               '-I',str(products/'Modules'),'-I',str(ROOT/'.build/checkouts/Yams/Sources/CYaml/include'),
               str(work/'HelperClient.swift'),str(ROOT/'script/check_app_update_choices.swift')]
    command += [str(p) for p in (ROOT/'Sources/LumaRoute/Stores').glob('*.swift')]
    command += [str(p) for name in ['LumaRouteCore','Yams','CYaml'] for p in (products/(name+'.build')).rglob('*.o')]
    subprocess.run(command+['-o',str(binary)],check=True)
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
    sockets = [socket.socket(),socket.socket()]
    for s in sockets: s.bind(('127.0.0.1',0))
    ports = [str(s.getsockname()[1]) for s in sockets]
    for s in sockets: s.close()
    subprocess.run([str(binary),*ports],env={**os.environ,'LUMAROUTE_DATA_DIR':str(work/'data')},check=True,timeout=45)

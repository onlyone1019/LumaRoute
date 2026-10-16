"""Exercise the production AppDelegate with real windows, without network/storage.

Requires a logged-in macOS desktop. --prepare builds the test app without
launching it, for interactive runners. Results are under work/dock-lifecycle/.
This checks lifecycle policy; actual Dock rendering still needs visual acceptance.
"""
from pathlib import Path
import json
import plistlib
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'work/dock-lifecycle'
WORK.mkdir(parents=True, exist_ok=True)
source = (ROOT / 'Sources/LumaRoute/App/LumaRouteApp.swift').read_text()
delegate = source[source.index('@MainActor\nfinal class AppDelegate:'):source.index('/// Identifies only')]
(WORK / 'AppDelegate.swift').write_text('import AppKit\nimport OSLog\n' + delegate)
build_script = (ROOT / 'script/build_and_run.sh').read_text()
plist_source = re.search(r"<<'PLIST'\n(.*?)\nPLIST", build_script, re.S).group(1)
production_plist = plistlib.loads(plist_source.encode())
app = WORK / 'DockLifecycleCheck.app'
binary = app / 'Contents/MacOS/DockLifecycleCheck'
binary.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O',
                str(WORK / 'AppDelegate.swift'), str(ROOT / 'script/check_dock_lifecycle.swift'),
                '-o', str(binary)], check=True)
with (app / 'Contents/Info.plist').open('wb') as file:
    plistlib.dump({'CFBundleIdentifier': 'app.lumaroute.dock-lifecycle-check',
                  'CFBundleExecutable': binary.name, 'CFBundleName': 'Dock lifecycle check',
                  'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '14.0',
                  'NSPrincipalClass': 'NSApplication',
                  'LSUIElement': production_plist.get('LSUIElement', False)}, file)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
report = WORK / 'result.json'
report.unlink(missing_ok=True)
print(app, flush=True)
if '--prepare' in sys.argv:
    sys.exit(0)
subprocess.run(['open', '-n', str(app)], check=True)
deadline = time.monotonic() + 30
while not report.exists() and time.monotonic() < deadline:
    time.sleep(0.1)
if not report.exists():
    raise RuntimeError('No lifecycle report; check that a macOS desktop session is available')
result = json.loads(report.read_text())
print(json.dumps(result, ensure_ascii=False, indent=2))
sys.exit(1 if result['failures'] else 0)

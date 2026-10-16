"""Exercise the production AppDelegate with real windows, without network/storage.

Requires a logged-in macOS desktop. --prepare builds the test app without
launching it, for interactive runners. Results are under work/dock-lifecycle/.
--observe-dock additionally checks actual tile counts using existing Accessibility
access, without prompting for permissions. --watch observes an app launched by an
interactive runner after --prepare; it does not rebuild or launch anything.
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
watch_only = '--watch' in sys.argv
observe = '--observe-dock' in sys.argv
app = WORK / 'DockLifecycleCheck.app'
report = WORK / 'result.json'
inspector = WORK / 'ReadDockLifecycle'

def observe_until_complete():
    observations = []
    last_phase = None
    dock_pid = None
    deadline = time.monotonic() + 90
    while not report.exists() and time.monotonic() < deadline:
        if observe:
            phase_file = WORK / 'dock-phase.json'
            phase = json.loads(phase_file.read_text()) if phase_file.exists() else None
            if phase and phase['id'] != last_phase:
                end = time.monotonic() + 2.5
                stable_since = None
                while True:
                    actual = json.loads(subprocess.check_output([str(inspector), str(app)], text=True))
                    if not actual.get('trusted') or 'count' not in actual:
                        raise RuntimeError('Read-only Dock observation unavailable; no permission was requested')
                    if dock_pid is None:
                        dock_pid = actual['dockPID']
                    assert actual['dockPID'] == dock_pid, 'Dock restarted during the check'
                    now = time.monotonic()
                    if actual['count'] == phase['count']:
                        stable_since = stable_since if stable_since is not None else now
                    else:
                        stable_since = None
                    passed = stable_since is not None and now - stable_since >= .2
                    if passed or now > end:
                        break
                    time.sleep(.08)
                ack = {'id': phase['id'], 'passed': passed}
                temp = WORK / 'dock-ack.tmp'
                temp.write_text(json.dumps(ack))
                temp.replace(WORK / 'dock-ack.json')
                observations.append({**phase, **actual, 'passed': passed})
                last_phase = phase['id']
        time.sleep(.05)
    (WORK / 'dock-observations.json').write_text(json.dumps(observations, indent=2))
    if not report.exists():
        raise RuntimeError('No lifecycle report; check that a macOS desktop session is available')
    result = json.loads(report.read_text())
    print(json.dumps(result, ensure_ascii=False, indent=2))
    sys.exit(1 if result['failures'] else 0)

if watch_only:
    observe_until_complete()
source = (ROOT / 'Sources/LumaRoute/App/LumaRouteApp.swift').read_text()
delegate = source[source.index('@MainActor\nfinal class AppDelegate:'):source.index('/// Identifies only')]
(WORK / 'AppDelegate.swift').write_text('import AppKit\nimport OSLog\n' + delegate)
build_script = (ROOT / 'script/build_and_run.sh').read_text()
plist_source = re.search(r"<<'PLIST'\n(.*?)\nPLIST", build_script, re.S).group(1)
production_plist = plistlib.loads(plist_source.encode())
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
report.unlink(missing_ok=True)
for name in ['observe-dock', 'dock-phase.json', 'dock-ack.json']:
    (WORK / name).unlink(missing_ok=True)
if observe:
    subprocess.run(['xcrun', 'swiftc', '-O', str(ROOT / 'script/read_dock_lifecycle.swift'),
                    '-o', str(inspector)], check=True)
    permission = json.loads(subprocess.check_output([str(inspector), str(app)], text=True))
    if not permission.get('trusted') or 'count' not in permission:
        raise RuntimeError('Read-only Dock observation unavailable; no permission was requested')
    (WORK / 'observe-dock').touch()
print(app, flush=True)
if '--prepare' in sys.argv:
    sys.exit(0)
subprocess.run(['open', '-n', str(app)], check=True)
observe_until_complete()

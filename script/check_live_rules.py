"""Regression for scrolling the production live rules page, then navigating away.

Uses synthetic rules in a private GUI host. Never bootstraps AppStore, reads
user data, starts a core/helper, or replaces the installed app. Requires a native
Release build and a macOS login session. The source copy only preselects the
private live tab; all production rendering and page caching remain intact.
"""
from pathlib import Path
import argparse
import fcntl
import json
import os
import platform
import plistlib
import signal
import subprocess
import tempfile
from build_environment import configure

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root', type=Path, default=ROOT)
parser.add_argument('--products', type=Path)
parser.add_argument('--output', type=Path)
parser.add_argument('--skip-build', action='store_true')
parser.add_argument('--interactive', action='store_true')
parser.add_argument('--rows', type=int, default=2000)
args = parser.parse_args()
if args.rows < 100:
    parser.error('--rows must be at least 100')
if args.skip_build and not args.output:
    parser.error('--skip-build requires --output')
sdk = configure()
products = (args.products or ROOT/f'.build/{platform.machine()}-apple-macosx/release').resolve()
arch = subprocess.check_output(['lipo', '-archs', str(products/'LumaRoute')], text=True).strip()
if arch not in ['arm64', 'x86_64']:
    raise ValueError('GUI check requires one architecture')
source = args.source_root.resolve()/'Sources/LumaRoute'
work = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix='lumaroute-live-rules-'))
work.mkdir(parents=True, exist_ok=True)
lock = (work/'run.lock').open('w')
fcntl.flock(lock, fcntl.LOCK_EX)
app = work/'LiveRulesCheck.app'
binary = app/'Contents/MacOS/LiveRulesCheck'
binary.parent.mkdir(parents=True, exist_ok=True)
page = work/'RulesPage.swift'
original = (source/'Views/RulesPage.swift').read_text()
initial = '@State private var tab="custom"'
if original.count(initial) != 1:
    raise RuntimeError('RulesPage initial-tab declaration changed; update fixture entry selection')
page.write_text(original.replace(initial, '@State private var tab="live"'))
include = ROOT/f'.build/{arch}/checkouts/Yams/Sources/CYaml/include'
if not include.exists():
    include = ROOT/'.build/checkouts/Yams/Sources/CYaml/include'
command = ['xcrun', 'swiftc', '-O', '-whole-module-optimization', '-parse-as-library',
           '-swift-version', '6', '-warnings-as-errors', '-sdk', sdk, '-target', arch+'-apple-macosx14.0',
           '-I', str(products/'Modules'), '-I', str(include), str(ROOT/'script/check_live_rules.swift'), str(page)]
command += [str(p) for folder in ['Views', 'Stores', 'Support', 'App'] for p in sorted((source/folder).glob('*.swift'))
            if p.name not in ['RulesPage.swift', 'LumaRouteApp.swift', 'AppUpdater.swift']]
command += [str(p) for name in ['LumaRouteCore', 'Yams', 'CYaml'] for p in sorted((products/(name+'.build')).rglob('*.o'))]
command += ['-o', str(binary)]
if not args.skip_build:
    subprocess.run(command, check=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
    CFBundleIdentifier='app.lumaroute.live-rules-check', CFBundleExecutable='LiveRulesCheck',
    CFBundleName='LumaRoute 生效规则回归', CFBundlePackageType='APPL',
    LSUIElement=not args.interactive, LSMinimumSystemVersion='14.0', NSPrincipalClass='NSApplication')))
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
report = work/'result.json'
progress = work/'progress.json'
stderr = work/'stderr.log'
for path in ([progress, stderr] if args.interactive else [report, progress, stderr]):
    path.unlink(missing_ok=True)
launch = ['open', '-n', '--arch', arch, str(app), '--stderr', str(stderr), '--args', str(work), str(args.rows)]
if args.interactive:
    subprocess.run(launch+['interactive'], check=True)
    print('Interactive isolated host:', app)
    raise SystemExit(0)
launcher = subprocess.Popen(launch[:1]+['-W']+launch[1:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
try:
    output, _ = launcher.communicate(timeout=90)
    if launcher.returncode or not report.exists():
        raise RuntimeError('GUI did not complete: '+output.strip())
    result = json.loads(report.read_text())
except (subprocess.TimeoutExpired, RuntimeError) as error:
    result = dict(failures=[str(error)])
finally:
    if progress.exists():
        pid = json.loads(progress.read_text())['pid']
        identity = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True)
        if identity.stdout.strip() == str(binary):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    if launcher.poll() is None:
        launcher.terminate()
        launcher.communicate(timeout=5)
warnings = stderr.read_text(errors='replace').count('reentrant operation in its NSTableView delegate') if stderr.exists() else 0
if warnings:
    result['failures'].append(str(warnings)+' AppKit table reentrancy warnings')
result['reentrant_warnings'] = warnings
report.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
print(json.dumps(result, ensure_ascii=False, indent=2))
raise SystemExit(bool(result['failures']))

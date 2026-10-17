"""Continuous native GUI regression for the real connections page.

Uses synthetic snapshots and private SQLite only. Never starts a core/helper or
reads real app data. Requires a macOS login session and an existing native build.
AppKit reentrancy warnings, premature exits and timeouts fail this check.
"""
from pathlib import Path
import argparse
import json
import os
import plistlib
import fcntl
import signal
import subprocess
import tempfile
import platform
from build_environment import configure

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--products', type=Path, help='Native Release products folder (contains Modules and target .build folders)')
parser.add_argument('--source-root', type=Path, default=ROOT)
parser.add_argument('--output', type=Path)
parser.add_argument('--modes', nargs='+', choices=['direct', 'container'], default=['direct', 'container'])
parser.add_argument('--soak-seconds', type=int, default=0, help='Additional steady refresh per mode, including real idle eviction after 60 seconds')
parser.add_argument('--skip-build', action='store_true', help="Reuse this output folder's fixture for debugging")
args = parser.parse_args()
if args.soak_seconds < 0:
    parser.error('--soak-seconds must be nonnegative')
sdk = configure()
if args.skip_build and not args.output:
    parser.error('--skip-build requires --output')
host_arch = platform.machine()
architecture_products = ROOT/f'.build/{host_arch}/{host_arch}-apple-macosx/release'
default_products = architecture_products if architecture_products.exists() else ROOT/f'.build/{host_arch}-apple-macosx/release'
products = (args.products or default_products).resolve()
source = args.source_root.resolve()/'Sources/LumaRoute'
work = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix='lumaroute-connection-gui-'))
work.mkdir(parents=True, exist_ok=True)
run_lock = (work/"run.lock").open("w")
fcntl.flock(run_lock, fcntl.LOCK_EX)
app = work/'ConnectionTableCheck.app'
binary = app/'Contents/MacOS/ConnectionTableCheck'
binary.parent.mkdir(parents=True, exist_ok=True)
arch = subprocess.check_output(['lipo', '-archs', str(products/'LumaRoute')], text=True).strip()
if arch not in ['arm64', 'x86_64']:
    raise ValueError('GUI check requires one architecture')
include = ROOT/f'.build/{arch}/checkouts/Yams/Sources/CYaml/include'
command = ['xcrun', 'swiftc', '-O', '-whole-module-optimization', '-g', '-parse-as-library',
           '-swift-version', '6', '-warnings-as-errors', '-sdk', sdk, '-target', arch+'-apple-macosx14.0',
           '-I', str(products/'Modules'), '-I', str(include), str(ROOT/'script/check_connection_table.swift')]
command += [str(p) for folder in ['Views', 'Stores', 'Support', 'App'] for p in sorted((source/folder).glob('*.swift')) if p.name not in ['LumaRouteApp.swift', 'AppUpdater.swift']]
command += [str(p) for name in ['LumaRouteCore', 'Yams', 'CYaml'] for p in sorted((products/(name+'.build')).rglob('*.o'))]
command += ['-o', str(binary)]
if not args.skip_build:
    subprocess.run(command, cwd=work, check=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
    CFBundleIdentifier='app.lumaroute.connection-table-check', CFBundleExecutable='ConnectionTableCheck',
    CFBundleName='ConnectionTableCheck', CFBundlePackageType='APPL', LSUIElement=True,
    LSMinimumSystemVersion='14.0', NSPrincipalClass='NSApplication')))
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
failures = []
for mode in args.modes:
    report = work/(mode+'.json')
    progress = work/(mode+'-progress.json')
    stderr = work/(mode+'.stderr')
    for path in [report, progress, stderr]:
        path.unlink(missing_ok=True)
    launch = ['open', '-W', '-n', '--arch', arch, str(app), '--stderr', str(stderr), '--args', str(work), mode, str(args.soak_seconds)]
    launcher = subprocess.Popen(launch, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        output, _ = launcher.communicate(timeout=120+args.soak_seconds)
        if launcher.returncode:
            raise RuntimeError('native GUI could not launch: '+output.strip())
        if not report.exists():
            detail = progress.read_text() if progress.exists() else 'no startup report'
            raise RuntimeError('native GUI exited without completion: '+detail)
        result = json.loads(report.read_text())
        warnings = stderr.read_text(errors='replace').count('reentrant operation in its NSTableView delegate')
        result['reentrant_warnings'] = warnings
        if warnings:
            result['failures'].append(str(warnings)+' AppKit table reentrancy warnings')
        report.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
        failures += [mode+': '+failure for failure in result['failures']]
        print(mode+': '+str(result['updates'])+' updates; '+str(len(result['checks']))+' checks; '+str(warnings)+' reentrancy warnings; '+str(result['soak_updates'])+' steady updates', flush=True)
    except (subprocess.TimeoutExpired, RuntimeError) as error:
        failures.append(mode+': '+str(error))
    finally:
        if launcher.poll() is None:
            if progress.exists():
                pid = json.loads(progress.read_text())['pid']
                identity = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True)
                if identity.stdout.strip() == str(binary):
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            launcher.terminate()
            launcher.communicate(timeout=5)
(work/'result.json').write_text(json.dumps(dict(architecture=arch, failures=failures), ensure_ascii=False, indent=2)+'\n')
print('Artifacts: '+str(work), flush=True)
if failures:
    raise SystemExit('\n'.join(failures))
print('PASS continuous connections GUI regression')

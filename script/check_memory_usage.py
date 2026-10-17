"""Compare Release native UI memory without bootstrapping the live app or core.

Run --baseline before editing, then run without it. Inputs are synthetic; reports
and frozen baseline sources stay in git-ignored work/memory-optimization-2026-10-16.
"""
from build_environment import configure
from pathlib import Path
import argparse
import fcntl
import json
import plistlib
import shutil
import subprocess
import time

SDK = configure()

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'work/memory-optimization-2026-10-16'
parser = argparse.ArgumentParser()
parser.add_argument('--baseline', action='store_true')
parser.add_argument('--run-only', action='store_true')
parser.add_argument('--label')
parser.add_argument('--interactive', action='store_true')
args = parser.parse_args()
WORK.mkdir(parents=True, exist_ok=True, mode=0o700)
# Compiling or displaying a second native host would distort navigation timings.
run_lock = (WORK / 'run.lock').open('w')
fcntl.flock(run_lock, fcntl.LOCK_EX)
label = args.label or ('before' if args.baseline else 'after')
frozen = WORK / 'before-sources'
if args.baseline and not frozen.exists():
    shutil.copytree(ROOT / 'Sources/LumaRoute', frozen)
sources = frozen if args.baseline else ROOT / 'Sources/LumaRoute'
products = WORK / 'products'
if not products.exists():
    products.mkdir()
    for p in (ROOT / '.build/out/Products/Release').iterdir():
        if p.suffix == '.swiftmodule':
            shutil.copytree(p, products / p.name)
        elif p.suffix == '.o':
            shutil.copy2(p, products / p.name)
app = WORK / (label + '.app')
(app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
command = ['xcrun', 'swiftc', '-O', '-parse-as-library', '-target',
           'arm64-apple-macosx14.0', '-sdk',
           SDK,
           '-I', str(products), '-I', str(ROOT / '.build/checkouts/Yams/Sources/CYaml/include')]
if not args.baseline:
    command += ['-D', 'MEMORY_OPTIMIZED']
command += [str(ROOT / 'script/check_memory_usage.swift')]
command += [str(p) for p in (sources / 'App').glob('*.swift') if p.name != 'LumaRouteApp.swift']
for folder in ['Views', 'Stores', 'Support']:
    command += [str(p) for p in (sources / folder).glob('*.swift')]
command += [str(products / n) for n in ['LumaRouteCore.o', 'Yams.o', 'CYaml.o']]
command += ['-o', str(app / 'Contents/MacOS/MemoryCheck')]
if not args.run_only:
    subprocess.run(command, cwd=ROOT, check=True)
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier': 'app.lumaroute.memory-check-' + label,
                  'CFBundleExecutable': 'MemoryCheck', 'CFBundleName': 'LumaRoute Memory QA',
                  'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '14.0',
                  'NSPrincipalClass': 'NSApplication', 'LSUIElement': True}, f)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
report = WORK / (label + '.json')
if not args.interactive:
    report.unlink(missing_ok=True)
launch = ['open', '-n', str(app), '--args', str(WORK), label]
if args.interactive:
    launch.append('interactive')
subprocess.run(launch, check=True)
if args.interactive:
    print('Interactive isolated host:', app)
    raise SystemExit(0)
deadline = time.monotonic() + 180
while not report.exists() and time.monotonic() < deadline:
    time.sleep(.2)
if not report.exists():
    raise RuntimeError('Native memory check did not finish')
result = json.loads(report.read_text())
print(json.dumps(result, ensure_ascii=False, indent=2))
if result['failures']:
    raise SystemExit(1)

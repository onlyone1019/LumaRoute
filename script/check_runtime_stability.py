"""Real AppStore/CoreRunner regressions with loopback-only cores and a fake helper.

Requires a native SwiftPM build and a bundled Mihomo executable with GEO resources.
All databases, runtime files and executables stay under --output; no XPC is used.
"""
from build_environment import configure
from pathlib import Path
import argparse
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, required=True)
parser.add_argument('--core', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
sdk = configure()
products = args.products.resolve()
work = args.output.resolve()
work.mkdir(parents=True, exist_ok=True)
build_root = products.parent.parent
binary = work / 'runtime-stability-check'
command = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
           '-target', 'arm64-apple-macosx14.0', '-sdk', sdk,
           '-I', str(products / 'Modules'),
           '-I', str(build_root / 'checkouts/Yams/Sources/CYaml/include')]
command += [str(ROOT / path) for path in [
    'script/check_runtime_stability.swift', 'Tests/Fixtures/stability_helper.swift',
    'Sources/LumaRoute/Stores/AppStore.swift', 'Sources/LumaRoute/Stores/RuleSubscriptionStore.swift',
    'Sources/LumaRoute/Stores/RuntimeData.swift']]
for target in ['LumaRouteCore', 'Yams', 'CYaml']:
    objects = sorted((products / (target + '.build')).rglob('*.o'))
    if not objects:
        raise SystemExit('Missing native build objects for ' + target)
    command += [str(path) for path in objects]
subprocess.run(command + ['-o', str(binary)], cwd=ROOT, check=True)
subprocess.run([str(binary), str(work / 'data'), str(args.core.resolve())], cwd=ROOT,
               check=True, timeout=120)

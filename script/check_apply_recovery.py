"""Exercise HelperController without root access, real cores or network changes.

Build the package first. --products selects an isolated build's product folder.
--baseline checks the current HEAD controller against the same regression cases.
"""
from build_environment import configure
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=ROOT / '.build/out/Products/Release')
parser.add_argument('--sdk', help='Path to another supported macOS 27.0 / 27.2 SDK; defaults to the active Xcode SDK')
parser.add_argument('--baseline', action='store_true')
args = parser.parse_args()

with tempfile.TemporaryDirectory(prefix='lumaroute-helper-apply-') as directory:
    work = Path(directory)
    users = work / 'service/users'
    users.mkdir(parents=True, mode=0o700)
    (work / 'service').chmod(0o700)
    controller_source = ROOT / 'Sources/LumaRouteHelper/HelperController.swift'
    if args.baseline:
        # HEAD before the controller was split stays available for comparisons.
        source = subprocess.check_output(
            ['git', 'show', 'HEAD:Sources/LumaRouteHelper/main.swift'], cwd=ROOT, text=True,
        )
        if 'actor HelperController {' in source:
            controller = source[source.index('actor HelperController {'):source.index('\nfinal class ClientHandler:')]
            # Only the generated fixture changes its filesystem root/expected owner.
            # Production ownership checks and paths remain untouched.
            assert controller.count('owner.uint32Value == 0') == 1
            controller = controller.replace('/Library/Application Support/LumaRoute/users', str(users))
            controller = controller.replace('owner.uint32Value == 0', 'owner.uint32Value == getuid()')
            generated = work / 'HelperController.swift'
            generated.write_text('import Foundation\nimport LumaRouteCore\n' + controller)
            controller_source = generated
        else:
            controller_source = work / 'HelperController.swift'
            controller_source.write_text(subprocess.check_output(
                ['git', 'show', 'HEAD:Sources/LumaRouteHelper/HelperController.swift'], cwd=ROOT, text=True,
            ))
    binary = work / 'apply-recovery-check'
    products = args.products.resolve()
    sdk = configure(args.sdk)
    native = (products / 'Modules').is_dir()
    build_root = products.parent.parent if native else ROOT / '.build'
    command = ['xcrun', 'swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macosx14.0',
               '-sdk', sdk, '-I', str(products / 'Modules' if native else products),
               '-I', str(build_root / 'checkouts/Yams/Sources/CYaml/include'),
               str(controller_source), str(ROOT / 'script/check_apply_recovery.swift')]
    if not args.baseline or '#if HELPER_RECOVERY_TEST' in controller_source.read_text():
        command += ['-D', 'HELPER_RECOVERY_TEST']
    if native:
        for target in ['LumaRouteCore', 'Yams', 'CYaml']:
            command += [str(path) for path in sorted((products / (target + '.build')).rglob('*.o'))]
    else:
        command += [str(products / name) for name in ['LumaRouteCore.o', 'Yams.o', 'CYaml.o']]
    subprocess.run(command + ['-o', str(binary)], cwd=work, check=True)
    subprocess.run([str(binary), str(work)], cwd=work, check=True, timeout=30)

"""Exercise HelperController without root access, real cores or network changes.

Build the package first. --products selects an isolated build's product folder.
--baseline checks the current HEAD controller against the same regression cases.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=ROOT / '.build/out/Products/Release')
parser.add_argument('--sdk', help='SDK used to build the selected products; defaults to the active SDK')
parser.add_argument('--baseline', action='store_true')
args = parser.parse_args()

with tempfile.TemporaryDirectory(prefix='lumaroute-helper-apply-') as directory:
    work = Path(directory)
    users = work / 'service/users'
    users.mkdir(parents=True, mode=0o700)
    (work / 'service').chmod(0o700)
    source = (subprocess.check_output(['git', 'show', 'HEAD:Sources/LumaRouteHelper/main.swift'], cwd=ROOT, text=True)
              if args.baseline else (ROOT / 'Sources/LumaRouteHelper/main.swift').read_text())
    controller = source[source.index('actor HelperController {'):source.index('\nfinal class ClientHandler:')]
    # Only the generated fixture changes its filesystem root/expected owner.
    # Production ownership checks and paths remain untouched.
    assert controller.count('owner.uint32Value == 0') == 1
    controller = controller.replace('/Library/Application Support/LumaRoute/users', str(users))
    controller = controller.replace('owner.uint32Value == 0', 'owner.uint32Value == getuid()')
    generated = work / 'HelperController.swift'
    generated.write_text('import Foundation\nimport LumaRouteCore\n' + controller)
    binary = work / 'apply-recovery-check'
    products = args.products.resolve()
    sdk = args.sdk or subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    command = ['xcrun', 'swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macosx14.0',
               '-sdk', sdk, '-I', str(products),
               '-I', str(ROOT / '.build/checkouts/Yams/Sources/CYaml/include'),
               str(generated), str(ROOT / 'script/check_apply_recovery.swift')]
    command += [str(products / name) for name in ['LumaRouteCore.o', 'Yams.o', 'CYaml.o']]
    subprocess.run(command + ['-o', str(binary)], cwd=work, check=True)
    subprocess.run([str(binary), str(work)], cwd=work, check=True, timeout=30)

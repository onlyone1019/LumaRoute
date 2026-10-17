"""Compile the production XPC handler in Swift 6 and exercise concurrent replies.

Only the controller's privileged effects are replaced. No helper is installed,
no real XPC connection/core starts, and no system network state is changed.
"""
from build_environment import configure
from pathlib import Path
import argparse
import subprocess
import tempfile

SDK = configure()

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=ROOT / '.build/out/Products/Release')
args = parser.parse_args()
source = (ROOT / 'Sources/LumaRouteHelper/main.swift').read_text()
handler = source[source.index('final class ClientHandler:'):source.index('\nfinal class ListenerDelegate:')]

with tempfile.TemporaryDirectory(prefix='lumaroute-helper-concurrency-') as directory:
    work = Path(directory)
    generated = work / 'ClientHandler.swift'
    generated.write_text('import Foundation\nimport LumaRouteCore\n' + handler)
    products = args.products.resolve()
    binary = work / 'helper-concurrency-check'
    command = ['xcrun', 'swiftc', '-sdk', SDK, '-O', '-parse-as-library', '-swift-version', '6',
               '-strict-concurrency=complete', '-warnings-as-errors', '-I', str(products),
               '-I', str(ROOT / '.build/checkouts/Yams/Sources/CYaml/include'),
               str(generated), str(ROOT / 'script/check_helper_concurrency.swift')]
    command += [str(products / name) for name in ['LumaRouteCore.o', 'Yams.o', 'CYaml.o']]
    subprocess.run(command + ['-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)

"""Run the production AppStore against continuous loopback traffic/log streams.

CoreRunner and HelperClient effects are replaced by the Swift fixture; no real
core, privileged service, app window or system network settings are touched.
Build first; --products selects an isolated build and --baseline uses all Stores
sources from one HEAD commit instead of the working tree or --source-root.
Use --preparation-check for YAML/metadata/UI-heartbeat regressions, and
--source-root for a frozen source snapshot in before/after checks.
"""
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from build_environment import configure
from pathlib import Path
import argparse
import json
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
STORES = Path('Sources/LumaRoute/Stores')
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=ROOT / '.build/out/Products/Release')
parser.add_argument('--sdk')
parser.add_argument('--baseline', action='store_true', help='Compile the Stores sources from HEAD')
parser.add_argument('--preparation-check', action='store_true', help='Check YAML preparation and main-thread responsiveness')
parser.add_argument('--source-root', type=Path, default=ROOT, help='Source snapshot for before/after checks')
args = parser.parse_args()
counts = Counter()
lock = threading.Lock()
sequence = 0
stop = threading.Event()
subscription_file = None


def store_sources(destination):
    if not args.baseline:
        return sorted((args.source_root.resolve() / STORES).glob('*.swift'))

    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD^{commit}'], cwd=ROOT, text=True).strip()
    tracked = subprocess.check_output(
        ['git', 'ls-tree', '-r', '-z', '--name-only', revision, '--', STORES.as_posix()], cwd=ROOT,
    ).decode().split('\0')
    destination.mkdir()
    sources = []
    for path in map(Path, tracked):
        if path.parent != STORES or path.suffix != '.swift':
            continue
        source = destination / path.name
        source.write_bytes(subprocess.check_output(['git', 'show', f'{revision}:{path.as_posix()}'], cwd=ROOT))
        sources.append(source)
    return sources


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass  # Stream task cancellation intentionally closes the connection.

    def do_GET(self):
        if self.path == '/subscription' and subscription_file is not None:
            body = subscription_file.read_bytes()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == '/proxies' and args.preparation_check:
            body = b'{"proxies":{}}'
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        global sequence
        if self.path == '/stats':
            with lock:
                body = json.dumps(dict(counts)).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path not in ['/traffic', '/logs']:
            self.send_error(404)
            return
        with lock:
            counts[self.path] += 1
        self.send_response(200)
        self.send_header('Content-Type', 'application/x-ndjson')
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        try:
            while not stop.is_set():
                with lock:
                    sequence += 1
                    number = sequence
                value = ({'up': number, 'down': number * 2} if self.path == '/traffic'
                         else {'type': 'info', 'payload': 'stream-' + str(number)})
                body = (json.dumps(value) + '\n').encode()
                self.wfile.write(('%x\r\n' % len(body)).encode() + body + b'\r\n')
                self.wfile.flush()
                stop.wait(.06)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='lumaroute-stream-recovery-') as directory:
        work = Path(directory)
        subscription_file = work / 'subscription.yaml'
        products = args.products.resolve()
        sdk = configure(args.sdk)
        sources = store_sources(work / 'stores')
        if not any(path.name == 'AppStore.swift' for path in sources):
            raise SystemExit('Missing AppStore.swift in the selected Stores sources')
        binary = work / 'stream-recovery-check'
        fixture = ROOT / 'script/check_stream_recovery.swift'
        if args.preparation_check:
            fixture = work / 'PreparationCheck.swift'
            doubles = (ROOT / 'script/check_stream_recovery.swift').read_text().split('@main struct StreamRecoveryCheck', 1)[0]
            fixture.write_text(doubles + (ROOT / 'script/check_configuration_preparation.swift').read_text())
        native = (products / 'Modules').is_dir()
        build_root = products.parent.parent if native else ROOT / '.build'
        command = ['xcrun', 'swiftc', '-O', '-parse-as-library', '-swift-version', '6',
                   '-target', 'arm64-apple-macosx14.0', '-sdk', sdk,
                   '-I', str(products / 'Modules' if native else products),
                   '-I', str(build_root / 'checkouts/Yams/Sources/CYaml/include'),
                   str(fixture), *map(str, sources)]
        for name in ['LumaRouteCore', 'Yams', 'CYaml']:
            objects = sorted((products / (name + '.build')).rglob('*.o')) if native else [products / (name + '.o')]
            if not objects or not all(obj.is_file() for obj in objects):
                raise SystemExit('Missing build objects for ' + name)
            command.extend(map(str, objects))
        subprocess.run(command + ['-o', str(binary)], cwd=work, check=True)
        subprocess.run([str(binary), str(server.server_port), str(work / 'data')], cwd=work, check=True, timeout=45)
finally:
    stop.set()
    server.shutdown()
    server.server_close()

"""Verify the production chain UI/store against two loopback CONNECT proxies.

Requires a native SwiftPM debug build. --ui leaves an isolated preview open.
Only the generated AppStore copy disables installed-service selection; no host
proxy, TUN, service installation, or user's data is changed.
"""
from build_environment import configure
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import json
import plistlib
import select
import socket
import subprocess
import threading

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'work/proxy-chains-20261027'
WORK.mkdir(parents=True, exist_ok=True)
parser = argparse.ArgumentParser()
parser.add_argument('--ui', action='store_true')
args = parser.parse_args()
events = []
servers = []


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == '/reset':
            events.clear()
        payload = (json.dumps(events) if self.path == '/events' else
                   f"proxies: [{{name: HK, type: http, server: 127.0.0.1, port: {upstream}}}, "
                   f"{{name: 'VPS.(美国)+', type: http, server: 127.0.0.1, port: {landing}}}]"
                   if self.path == '/provider' else 'origin').encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_CONNECT(self):
        target = self.path
        if target == 'origin.fixture.test:80':
            address = ('127.0.0.1', origin)
        else:
            host, port = target.rsplit(':', 1)
            if host != '127.0.0.1' or int(port) not in (origin, landing):
                self.send_error(403)
                return
            address = (host, int(port))
        events.append(self.server.role+':'+target)
        with socket.create_connection(address, timeout=5) as remote:
            self.send_response(200)
            self.end_headers()
            self.wfile.flush()
            self.connection.settimeout(10)
            while True:
                ready, _, _ = select.select([self.connection, remote], [], [], 10)
                if not ready:
                    break
                for peer in ready:
                    data = peer.recv(65536)
                    if not data:
                        return
                    (remote if peer is self.connection else self.connection).sendall(data)


def serve(role):
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.role = role
    servers.append(server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_port


def unused_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


origin = serve('origin')
landing = serve('landing')
upstream = serve('upstream')
sdk = configure()
products = ROOT / '.build/arm64-apple-macosx/debug'
source = (ROOT / 'Sources/LumaRoute/Stores/AppStore.swift').read_text()
needle = 'let serviceBackend = helper.localInstallation.map { !$0.healthOnly } ?? (helper.status == .enabled)'
assert source.count(needle) == 1
generated = WORK / 'AppStore.swift'
generated.write_text(source.replace(needle, 'let serviceBackend = false'))
files = [generated, ROOT / 'script/check_proxy_chains.swift']
files += [ROOT / 'Sources/LumaRoute' / name for name in (
    'Stores/RoutingStore.swift', 'Stores/RuleSubscriptionStore.swift',
    'Stores/RuntimeData.swift', 'Support/HelperClient.swift',
    'Views/ProxiesPage.swift', 'Views/ProxyChainsView.swift',
    'Views/ProxyGroupCard.swift', 'Views/GroupStrategySheet.swift',
    'Views/Components.swift', 'Views/Controls.swift', 'Views/Theme.swift')]
objects = []
for target in ('LumaRouteCore', 'Yams', 'CYaml'):
    objects += sorted((products / f'{target}.build').rglob('*.o'))
assert objects, 'Build the package with --build-system native first'
bundle = WORK / 'ProxyChainsCheck.app'
executable = bundle / 'Contents/MacOS/ProxyChainsCheck'
executable.parent.mkdir(parents=True, exist_ok=True)
(bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': 'ProxyChainsCheck', 'CFBundleIdentifier': 'app.lumaroute.chaincheck',
    'CFBundleName': 'ProxyChainsCheck', 'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '14.0'}))
command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
           '-target', 'arm64-apple-macosx14.0', '-sdk', sdk, '-I', str(products / 'Modules'),
           '-I', str(ROOT / '.build/checkouts/Yams/Sources/CYaml/include')]
subprocess.run(command + list(map(str, files + objects)) + ['-o', str(executable)], cwd=ROOT, check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True)
launch = [str(executable), str(WORK / ('ui-store' if args.ui else 'store')), str(ROOT / 'Resources/Core/mihomo-arm64'),
          str(upstream), str(landing), str(origin), str(unused_port()), str(unused_port())]
try:
    if args.ui:
        # A real bundle is launched through Launch Services for native UI review.
        subprocess.run(['open', '-n', str(bundle), '--args'] + launch[1:] + ['--ui'], check=True)
        print(f'UI fixture: {bundle}', flush=True)
        threading.Event().wait()
    else:
        subprocess.run(launch, cwd=ROOT, check=True, timeout=90)
finally:
    for server in servers:
        server.shutdown()

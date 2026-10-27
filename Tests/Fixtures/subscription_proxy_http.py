"""Loopback HTTP proxy fixture; returns a subscription for an unreachable URL."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        payload = b'proxies: []\nproxy-groups: []\nrules: []\nfixture-route: proxy\n'
        self.send_response(200 if self.path.startswith('http://127.0.0.1:1/sub/') else 400)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
Path(sys.argv[1], 'port').write_text(str(server.server_port))
server.serve_forever()

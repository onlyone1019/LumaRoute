"""Loopback subscription endpoint; echo the received UA without starting a core."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import json
import sys


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        content = ('proxies: []\nproxy-groups: []\nrules: []\nfixture-user-agent: '
                   + json.dumps(self.headers.get('User-Agent', '')) + '\n').encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        self.wfile.write(content)


server = HTTPServer(('127.0.0.1', 0), Handler)
port = Path(sys.argv[1], 'port')
temporary = port.with_suffix('.tmp')
temporary.write_text(str(server.server_port))
temporary.replace(port)
server.serve_forever()

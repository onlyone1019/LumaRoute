#!/usr/bin/python3
"""Loopback controller fixture. Never creates proxy listeners or changes networking."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import json
import os
import re
import sys

if '-t' in sys.argv:
    sys.exit(0)
# Python consumes CoreRunner's -d as its debug flag, then executes this
# directory's __main__.py. The process remains the verified Python executable.
home = Path(sys.argv[0])
text = Path(sys.argv[sys.argv.index('-f') + 1]).read_text()
port = int(re.search(r'127\.0\.0\.1:(\d+)', text).group(1))


def mode(yaml):
    return re.search(r'^mode:\s*[\"\']?(\w+)', yaml, re.M).group(1)


def scenario():
    file = home / 'scenario'
    return file.read_text() if file.exists() else ''


current = mode(text)
recovered = False
if current == 'global' and scenario() in ['restart-fails', 'rollback-restart-fails']:
    sys.exit(1)
if current == 'rule' and scenario() == 'rollback-restart-fails':
    sys.exit(1)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        fault = scenario()
        if self.path == '/version':
            self.reply(503 if recovered and fault == 'rollback-version-fails' else 200, {'version': 'fixture'})
        elif self.path == '/providers/proxies':
            failed = (current == 'global' and fault == 'candidate-providers-fail') or (recovered and fault == 'rollback-providers-fail')
            self.reply(503 if failed else 200, {'providers': {}})
        elif self.path == '/rules':
            self.reply(200, {'rules': [{'type': 'Match', 'payload': '', 'proxy': 'DIRECT'}]})
        elif self.path == '/configs':
            self.reply(200, {'mode': current, 'pid': os.getpid()})
        else:
            self.reply(404, {})

    def do_PUT(self):
        global current, recovered
        candidate = mode(json.loads(self.rfile.read(int(self.headers['Content-Length'])))['payload'])
        fault = scenario()
        if candidate == 'global':
            # A failed reload may already have changed runtime state.
            current = candidate
            recovered = False
            self.reply(204 if fault in ['success', 'candidate-providers-fail'] else 500, {})
        else:
            recovered = True
            if fault == 'rollback-reload-fails':
                self.reply(500, {})
                return
            current = candidate
            if fault == 'rollback-persist-fails':
                (home / 'active.yaml').unlink()
                (home / 'active.yaml').mkdir()
            self.reply(204, {})


class Server(HTTPServer):
    allow_reuse_address = True


Server(('127.0.0.1', port), Handler).serve_forever()

#!/usr/bin/env python3
"""Loopback-only subscription and HTTP proxy fixture for real Mihomo integration tests."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json, socket, socketserver, struct, threading, time
STATE = {"invalid": False, "tokyo_down": False, "osaka_down": False, "slow": False, "slow_timeout": False, "composition_b_tokyo": False, "composition_invalid": False}
METRICS = {"active": 0, "peak": 0, "started": 0}
METRICS_LOCK = threading.Lock()
PROFILE = """proxies:
  - {name: '日本 · 东京 01', type: http, server: 127.0.0.1, port: 18771}
  - {name: '日本 · 大阪 01', type: http, server: 127.0.0.1, port: 18773}
  - {name: '日本 · 东京 04', type: http, server: 127.0.0.1, port: 18779}
proxy-groups:
  - name: 默认代理
    type: select
    proxies: [日本自动, 日本 · 东京 01, 日本 · 大阪 01]
  - name: 日本自动
    type: url-test
    proxies: [日本 · 东京 01, 日本 · 大阪 01]
    url: http://127.0.0.1:18772/204
    interval: 60
    tolerance: 20
  - name: OpenAI
    type: select
    proxies: [日本自动, 日本 · 东京 01]
rules:
  - DOMAIN-SUFFIX,fixture.test,默认代理
  - MATCH,默认代理
"""
SLOW_PROFILE = "proxies:\n" + "".join(
    f"  - {{name: '验收测速 {i:02d}', type: http, server: 127.0.0.1, port: 18771}}\n"
    for i in range(1, 6)
) + "proxy-groups:\n  - {name: 验收测速组, type: select, proxies: [验收测速 01, 验收测速 02, 验收测速 03, 验收测速 04, 验收测速 05]}\nrules: ['MATCH,验收测速组']\n"
def composition_profile(port):
    return f"""proxies:
  - {{name: shared-node, type: http, server: 127.0.0.1, port: {port}}}
proxy-groups:
  - {{name: shared-group, type: select, include-all: true}}
rules:
  - DOMAIN-SUFFIX,base.fixture.test,shared-group
  - MATCH,shared-group
"""

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass
    def respond(self, status, payload=b"", headers=None):
        self.send_response(status)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        for key, value in (headers or {}).items(): self.send_header(key, value)
        self.end_headers()
        if payload and self.command != "HEAD":
            try: self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError): pass
    def do_HEAD(self):
        self.do_GET()
    def do_POST(self):
        if self.server.server_port != 18770 or self.path != "/state":
            return self.respond(404)
        values = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        for key in STATE:
            if key in values: STATE[key] = bool(values[key])
        if values.get("reset_metrics"):
            with METRICS_LOCK:
                METRICS["peak"] = METRICS["active"]
                METRICS["started"] = 0
        self.respond(200, json.dumps(STATE).encode())
    def do_GET(self):
        port = self.server.server_port
        if port == 18770:
            if self.path == "/ruleset/domain": return self.respond(200,b"payload:\n  - '+.fixture.test'\n")
            if self.path == "/ruleset/bad-domain": return self.respond(200,b"payload:\n  - DOMAIN,illegal\n")
            if self.path == "/ruleset/html": return self.respond(200,b"<html>not rules</html>")
            if self.path == "/ruleset/503": return self.respond(503,b"unavailable")
            if self.path == "/subscription-overflow":
                return self.respond(200, PROFILE.encode(), {
                    "Content-Type": "text/yaml",
                    "subscription-userinfo": "upload=9223372036854775807; download=1; total=100"
                })
            if self.path == "/subscription-agent-echo":
                payload = PROFILE + "\nfixture-user-agent: " + json.dumps(self.headers.get("User-Agent", "")) + "\n"
                return self.respond(200, payload.encode(), {"Content-Type": "text/yaml"})
            if self.path == "/subscription-required-agent":
                compatible = self.headers.get("User-Agent") == "LumaRoute-PerProfile/1.0"
                payload = PROFILE if compatible else "proxy-groups:\n  - {name: 默认代理, type: select, proxies: [日本自动]}\nrules: ['MATCH,默认代理']\n"
                return self.respond(200, payload.encode(), {"Content-Type": "text/yaml"})
            if self.path.startswith("/subscription-error/"):
                kind = self.path.rsplit("/", 1)[-1]
                if kind in ["401", "403", "404", "429", "503"]: return self.respond(int(kind), b"private response body must never be shown")
                if kind == "html": return self.respond(200, b"<!doctype html><html>private login page</html>")
                if kind == "empty": return self.respond(200)
                if kind == "encoding": return self.respond(200, b"\xff\xfe\xfd")
                if kind == "yaml": return self.respond(200, b"proxies: [unterminated")
                if kind == "json": return self.respond(200, b'{"error":"private account error"}')
                if kind == "oversize": return self.respond(200, b"#" * (8*1024*1024+1))
                if kind == "bom": return self.respond(200, ("\ufeff"+PROFILE).encode())
            if self.path == "/subscription-client-aware":
                # Model providers that negotiate their response from the client UA.
                compatible = self.headers.get("User-Agent", "").lower().startswith("clash.meta/")
                incomplete = "proxy-groups:\n  - {name: 默认代理, type: select, proxies: [日本自动]}\nrules: ['MATCH,默认代理']\n"
                return self.respond(200, (PROFILE if compatible else incomplete).encode(), {"Content-Type": "text/yaml"})
            if self.path == "/metrics":
                with METRICS_LOCK: payload = json.dumps(METRICS).encode()
                return self.respond(200, payload)
            if self.path == "/subscription-slow": return self.respond(200, SLOW_PROFILE.encode(), {"Content-Type": "text/yaml"})
            if self.path in ["/composition-a", "/composition-b"]:
                is_b = self.path.endswith("-b")
                content = "<html>invalid</html>" if is_b and STATE["composition_invalid"] else composition_profile(18773 if is_b and not STATE["composition_b_tokyo"] else 18771)
                return self.respond(200, content.encode(), {"Content-Type": "text/yaml"})
            if self.path == "/provider": return self.respond(200, b"<html>invalid provider</html>" if STATE["invalid"] else PROFILE.split("proxy-groups:", 1)[0].encode())
            if self.path == "/uri": return self.respond(200, b"http://127.0.0.1:18771#fixture-tokyo")
            if self.path != "/subscription":
                return self.respond(404)
            data = b"<html>invalid subscription</html>" if STATE["invalid"] else PROFILE.encode()
            self.respond(200, data, {
                "Content-Type": "text/yaml; charset=utf-8",
                "subscription-userinfo": "upload=1024; download=1048576; total=214748364800; expire=1798675200",
                "profile-update-interval": "6"
            })
            return
        if self.unavailable(): return
        if STATE["slow"] and port in [18771, 18773]:
            with METRICS_LOCK:
                METRICS["active"] += 1
                METRICS["started"] += 1
                METRICS["peak"] = max(METRICS["peak"], METRICS["active"])
            try: time.sleep(7 if STATE["slow_timeout"] else 3)
            finally:
                with METRICS_LOCK: METRICS["active"] -= 1
        time.sleep(0.025 if port == 18771 else 0.09 if port == 18773 else 0.015)
        if self.path.endswith("/hold"):
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            payload = b"LumaRoute fixture stream\n" * 128
            try:
                for _ in range(240):
                    self.wfile.write((hex(len(payload))[2:] + "\r\n").encode() + payload + b"\r\n")
                    self.wfile.flush()
                    time.sleep(0.5)
                self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError): pass
            self.close_connection = True
            return
        if self.path.endswith("/204"): return self.respond(204)
        payload = json.dumps({"fixture": True, "route": "tokyo" if port == 18771 else "osaka" if port == 18773 else "direct", "path": self.path}).encode()
        self.respond(200, payload, {"Content-Type": "application/json"})
    def do_CONNECT(self):
        if self.path not in ["127.0.0.1:18772", "[2001:db8::1]:80", "fixture.test:80", "airport.fixture.test:18772", "other.fixture.test:18772", "unrelated.test:18772", "a.fixture.test:80", "b.fixture.test:80", "child.b.fixture.test:80", "base.fixture.test:80", "other.test:80", "diagnostic.fixture.test:80", "diagnostic.fixture.test:18772"]:
            return self.respond(403, b"Only loopback fixture destinations are allowed.")
        if self.unavailable(): return
        self.send_response(200)
        self.end_headers()
        self.wfile.flush()
        request = self.rfile.readline(8192).decode("ascii", errors="replace").split()
        if len(request) != 3 or request[0] not in ["GET", "HEAD"]: return
        for _ in range(100):
            if self.rfile.readline(8192) in [b"\r\n", b"\n", b""]: break
        else: return
        self.command = request[0]
        self.path = request[1]
        self.do_GET()
    def unavailable(self):
        port = self.server.server_port
        if (port == 18771 and STATE["tokyo_down"]) or (port == 18773 and STATE["osaka_down"]):
            self.close_connection = True
            try: self.connection.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            self.connection.close()
            return True
        return False
class DNSHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, transport = self.request
        if len(data) < 17: return
        cursor, labels = 12, []
        while cursor < len(data) and data[cursor]:
            size = data[cursor]
            if size > 63 or cursor + 1 + size >= len(data): return
            labels.append(data[cursor+1:cursor+1+size].decode('ascii', errors='replace'))
            cursor += 1 + size
        if cursor + 5 > len(data): return
        kind = struct.unpack('!H', data[cursor+1:cursor+3])[0]
        name = '.'.join(labels)
        recognized = self.server.server_address[1] == 18774 and name in ['diagnostic.fixture.test', 'node-b.fixture.test']
        answer = recognized and kind == 1
        flags = 0x8180 if recognized else 0x8183
        payload = data[:2] + struct.pack('!HHHHH', flags, 1, int(answer), 0, 0) + data[12:cursor+5]
        if answer: payload += b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 30, 4) + socket.inet_aton('127.0.0.1')
        transport.sendto(payload, self.client_address)

servers = []
for dns_port in [18774, 18775]:
    dns_server = socketserver.ThreadingUDPServer(('127.0.0.1', dns_port), DNSHandler)
    servers.append(dns_server)
    threading.Thread(target=dns_server.serve_forever, daemon=True).start()
for port in [18770, 18771, 18772, 18773]:
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    servers.append(server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
Path("work/local-fixture.yaml").write_text(PROFILE)
print("fixture ready: http://127.0.0.1:18770/subscription", flush=True)
try:
    while True: time.sleep(1)
except KeyboardInterrupt:
    for server in servers: server.shutdown()


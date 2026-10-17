"""Exercise the real GUI AppStore against a loopback-only fake Mihomo API."""
from build_environment import configure
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import subprocess
import threading
import time

SDK = configure()

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "work/latency-crash-2026-10-14"
WORK.mkdir(parents=True, exist_ok=True)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        node = int(self.path.split("node-")[1].split("/")[0])
        time.sleep(0.008 + (node % 5) * 0.004)
        failed = node % 10 == 0
        body = json.dumps({"message": "fixture failure"} if failed else {"delay": 100 + node}).encode()
        self.send_response(504 if failed else 200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
products = ROOT / ".build/out/Products/Release"
binary = WORK / "check-latency-batch"
command = ["xcrun", "swiftc", "-O", "-g", "-parse-as-library", "-target", "arm64-apple-macosx14.0", "-sdk", SDK, "-I", str(products), "-I", str(ROOT / ".build/checkouts/Yams/Sources/CYaml/include")]
command += [str(ROOT / name) for name in ["script/check_latency_batch.swift", "Sources/LumaRoute/Stores/AppStore.swift", "Sources/LumaRoute/Stores/RuleSubscriptionStore.swift", "Sources/LumaRoute/Stores/RuntimeData.swift", "Sources/LumaRoute/Support/HelperClient.swift"]]
command += [str(products / name) for name in ["LumaRouteCore.o", "Yams.o", "CYaml.o"]]
command += ["-o", str(binary)]
subprocess.run(command, cwd=ROOT, check=True)
try:
    result = subprocess.run([str(binary), str(server.server_port)], cwd=ROOT, timeout=60)
    raise SystemExit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
finally:
    server.shutdown()

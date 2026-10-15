#!/usr/bin/env python3
"""Exercise bundled GEO categories through an isolated core and loopback HTTP."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import subprocess
import threading
import time
import urllib.request
import uuid


def port():
    with socket.socket() as connection:
        connection.bind(("127.0.0.1", 0))
        return connection.getsockname()[1]


def run(app, output, geodata=None):
    app = app.resolve()
    output.mkdir(parents=True, exist_ok=False)
    resources = app / "Contents/Resources"
    core = resources / "mihomo"
    home = output / "core"
    home.mkdir()
    manifest = json.loads((resources / "GeoData/release.json").read_text())
    for asset in manifest["assets"]:
        data = ((geodata or resources / "GeoData") / asset["name"]).read_bytes()
        if geodata is None:
            assert "sha256:" + hashlib.sha256(data).hexdigest() == asset["digest"]
        (home / asset["name"]).write_bytes(data)
    expected = {
        "bilibili.tv": "Intl", "cdn.bilibili.tv": "Intl",
        "biliintl.com": "Intl", "www.biliintl.com": "Intl",
        "p-bstarstatic.akamaized.net": "Intl", "p.bstarstatic.com": "Intl",
        "upos-bstar-mirrorakam.akamaized.net": "Intl",
        "upos-bstar1-mirrorakam.akamaized.net": "Intl", "apiintl.biliapi.net": "Intl",
        "sharepoint.cn": "SharePoint", "sharepoint.com": "SharePoint",
        "sharepointonline.com": "SharePoint", "tenant.sharepoint.com": "SharePoint",
        "tenant.sharepoint.cn": "SharePoint",
    }
    rejected = ["bilibili.tv.evil.invalid", "sharepoint.com.evil.invalid",
                "sub.p-bstarstatic.akamaized.net", "sub.apiintl.biliapi.net",
                "www.microsoft.com", "www.bilibili.com"]
    mixed, control = port(), port()
    secret = uuid.uuid4().hex
    config = {"mixed-port": mixed, "external-controller": f"127.0.0.1:{control}",
              "secret": secret, "mode": "rule", "log-level": "debug", "allow-lan": False,
              "geodata-mode": True, "geodata-loader": "standard", "geo-auto-update": False,
              "ipv6": False, "dns": {"enable": False},
              "hosts": {name: "127.0.0.1" for name in list(expected) + rejected},
              "proxy-groups": [{"name": name, "type": "select", "proxies": ["DIRECT"]}
                               for name in ["Intl", "SharePoint"]],
              "rules": ["GEOSITE,biliintl,Intl", "GEOSITE,sharepoint,SharePoint", "MATCH,REJECT"]}
    config_file = home / "config.json"
    config_file.write_text(json.dumps(config))
    subprocess.run([str(core), "-t", "-d", str(home.resolve()), "-f", str(config_file.resolve())],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def api(path):
        request = urllib.request.Request(f"http://127.0.0.1:{control}/{path}",
                                         headers={"Authorization": "Bearer " + secret})
        with opener.open(request, timeout=3) as response:
            return json.load(response)

    started, release = threading.Event(), threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            started.set()
            release.wait(8)
            data = b'{"route":"loopback"}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log = (output / "mihomo.log").open("w")
    process = subprocess.Popen([str(core), "-d", str(home.resolve()), "-f", str(config_file.resolve())],
                               stdout=log, stderr=subprocess.STDOUT)
    results = []
    try:
        for _ in range(80):
            try:
                api("version")
                break
            except Exception:
                assert process.poll() is None, "core exited during startup"
                time.sleep(0.1)
        else:
            raise AssertionError("isolated core startup timed out")
        rules = api("rules")["rules"]
        assert [(rule["payload"].lower(), rule["size"]) for rule in rules[:2]] == [("biliintl", 7), ("sharepoint", 3)]

        def request(host):
            return subprocess.run(["curl", "--disable", "--silent", "--show-error", "--fail",
                                   "--max-time", "6", "--noproxy", "", "--proxy",
                                   f"http://127.0.0.1:{mixed}",
                                   f"http://{host}:{server.server_port}/probe"], capture_output=True)

        with ThreadPoolExecutor(max_workers=1) as pool:
            for host, policy in expected.items():
                started.clear()
                release.clear()
                future = pool.submit(request, host)
                try:
                    assert started.wait(5), "request never reached loopback: " + host
                    connections = api("connections").get("connections", [])
                    current = next(connection for connection in connections if connection["metadata"]["host"] == host)
                    assert current["rule"].lower() == "geosite", current
                    assert current["rulePayload"].lower() == ("biliintl" if policy == "Intl" else "sharepoint"), current
                    assert policy in current["chains"], current
                finally:
                    release.set()
                response = future.result(timeout=8)
                assert response.returncode == 0 and json.loads(response.stdout)["route"] == "loopback", host
                results.append({"host": host, "policy": policy, "matched": True})
            for host in rejected:
                started.clear()
                response = request(host)
                assert response.returncode != 0 and not started.is_set(), "unexpected category match: " + host
                results.append({"host": host, "policy": "REJECT", "matched": False})
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"GEO routing passed: {len(expected)} positive and {len(rejected)} boundary checks")
    finally:
        release.set()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log.close()
        server.shutdown()
        server.server_close()
        config_file.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--geodata", type=Path)
    args = parser.parse_args()
    run(args.app, args.output,args.geodata)

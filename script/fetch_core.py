#!/usr/bin/env python3
"""Download pinned official Mihomo artifacts and verify GitHub asset digests."""
from pathlib import Path
import gzip, hashlib, json, urllib.request
ROOT = Path(__file__).resolve().parents[1]
VERSION = "v1.19.32"
def request(url):
    return urllib.request.Request(url, headers={"User-Agent": "LumaRoute-build/0.1"})
def fetch(url):
    with urllib.request.urlopen(request(url), timeout=90) as response:
        return response.read()
release = json.loads(fetch("https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/" + VERSION))
result = {"version": VERSION, "repository": "MetaCubeX/mihomo", "assets": []}
lock_path = ROOT / "Resources" / "Core" / "release.json"
previous = json.loads(lock_path.read_text()) if lock_path.exists() else {}
for arch, name in [
    ("arm64", f"mihomo-darwin-arm64-{VERSION}.gz"),
    ("x86_64", f"mihomo-darwin-amd64-compatible-{VERSION}.gz")
]:
    asset = next(a for a in release["assets"] if a["name"] == name)
    target = ROOT / "Resources" / "Core" / ("mihomo-" + arch)
    known = next((a for a in previous.get("assets", []) if a["name"] == name and a["arch"] == arch), None)
    if target.exists() and known and previous.get("version") == VERSION:
        actual = hashlib.sha256(target.read_bytes()).hexdigest()
        if actual == known.get("binary_sha256") and known.get("github_digest") == asset.get("digest"):
            result["assets"].append(known)
            print("verified", target.name, flush=True)
            continue
    print("downloading", name, flush=True)
    compressed = fetch(asset["browser_download_url"])
    digest = hashlib.sha256(compressed).hexdigest()
    expected = asset.get("digest")
    if expected and expected != "sha256:" + digest:
        raise RuntimeError("GitHub release digest mismatch: " + name)
    payload = gzip.decompress(compressed)
    target.write_bytes(payload)
    target.chmod(0o755)
    result["assets"].append({"arch": arch, "name": name, "url": asset["browser_download_url"],
        "release_sha256": digest, "github_digest": expected, "binary_sha256": hashlib.sha256(payload).hexdigest()})
lock_path.write_text(json.dumps(result, indent=2) + "\n")
for name in ["LICENSE", "README.md"]:
    data = fetch(f"https://raw.githubusercontent.com/MetaCubeX/mihomo/{VERSION}/{name}")
    (ROOT / "Resources" / "Licenses" / ("Mihomo-" + name)).write_bytes(data)


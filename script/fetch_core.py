#!/usr/bin/env python3
"""Download locked Mihomo artifacts without querying the GitHub release API."""
from pathlib import Path
import gzip
import hashlib
import json
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = "v1.19.32"


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "LumaRoute-build/0.1"})
    with urllib.request.urlopen(request, timeout=90) as response:
        return response.read()


def install(root, asset):
    expected = asset["release_sha256"]
    if asset["github_digest"] != "sha256:" + expected:
        raise RuntimeError("Inconsistent locked release digest: " + asset["name"])
    target = root / "Resources/Core" / ("mihomo-" + asset["arch"])
    if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == asset["binary_sha256"]:
        target.chmod(0o755)
        print("verified", target.name, flush=True)
        return
    print("downloading", asset["name"], flush=True)
    compressed = fetch(asset["url"])
    if hashlib.sha256(compressed).hexdigest() != expected:
        raise RuntimeError("Locked release checksum mismatch: " + asset["name"])
    payload = gzip.decompress(compressed)
    if hashlib.sha256(payload).hexdigest() != asset["binary_sha256"]:
        raise RuntimeError("Locked binary checksum mismatch: " + asset["name"])
    temporary = target.with_name(target.name + ".partial")
    temporary.write_bytes(payload)
    temporary.chmod(0o755)
    temporary.replace(target)


def main(root=ROOT):
    release = json.loads((root / "Resources/Core/release.json").read_text())
    if release["version"] != VERSION or release["repository"] != "MetaCubeX/mihomo":
        raise RuntimeError("Unexpected Mihomo release lock")
    for arch, name in [
        ("arm64", f"mihomo-darwin-arm64-{VERSION}.gz"),
        ("x86_64", f"mihomo-darwin-amd64-compatible-{VERSION}.gz"),
    ]:
        asset = next(a for a in release["assets"] if a["arch"] == arch and a["name"] == name)
        expected_url = f"https://github.com/MetaCubeX/mihomo/releases/download/{VERSION}/{name}"
        if asset["url"] != expected_url:
            raise RuntimeError("Unexpected Mihomo download URL")
        install(root, asset)


if __name__ == "__main__":
    main()

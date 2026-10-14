#!/usr/bin/env python3
"""Bundle verified official rule databases so importing does not need bootstrap downloads."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib, json, urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "Resources" / "GeoData"
LOCK = DEST / "release.json"
DEST.mkdir(parents=True, exist_ok=True)

def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "LumaRoute-build/0.1"})
    with urllib.request.urlopen(request, timeout=90) as response:
        return response.read()

if LOCK.exists():
    release = json.loads(LOCK.read_text())
else:
    metadata = json.loads(fetch("https://api.github.com/repos/MetaCubeX/meta-rules-dat/releases/tags/latest"))
    names = {"geoip.metadb": "geoip.metadb", "geoip.dat": "GeoIP.dat", "geosite.dat": "GeoSite.dat"}
    assets = []
    for asset in metadata["assets"]:
        if asset["name"] in names:
            if not (asset.get("digest") or "").startswith("sha256:"):
                raise RuntimeError("Official asset has no SHA256 digest")
            assets.append({"name": names[asset["name"]], "url": asset["browser_download_url"],
                           "digest": asset["digest"], "updated_at": asset["updated_at"]})
    if len(assets) != len(names):
        raise RuntimeError("Missing official database assets")
    release = {"repository": "MetaCubeX/meta-rules-dat", "assets": assets}

def install(asset):
    path = DEST / asset["name"]
    if path.exists() and "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest() == asset["digest"]:
        print("verified", asset["name"], flush=True)
        return
    payload = fetch(asset["url"])
    if "sha256:" + hashlib.sha256(payload).hexdigest() != asset["digest"]:
        raise RuntimeError("Database checksum mismatch: " + asset["name"])
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_bytes(payload)
    temporary.replace(path)
    print("installed", asset["name"], len(payload), flush=True)

with ThreadPoolExecutor(max_workers=3) as pool:
    list(pool.map(install, release["assets"]))
LOCK.write_text(json.dumps(release, indent=2) + "\n")

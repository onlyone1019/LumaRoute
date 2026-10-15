#!/usr/bin/env python3
"""Verify cached GEO data, or rebuild offline from the pinned input snapshot."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
from geosite_sources import verify_policy

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "Resources/GeoData"
release = json.loads((DEST / "release.json").read_text())
verify_policy(DEST / release["input_snapshot"], DEST / "GeoSite-policy.json")
valid = True
for asset in release["assets"]:
    path = DEST / asset["name"]
    if path.exists() and "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest() == asset["digest"]:
        print("verified", asset["name"], flush=True)
    else:
        valid = False
if not valid:
    subprocess.run([sys.executable, str(ROOT / "script/rebuild_geodata.py")], check=True)

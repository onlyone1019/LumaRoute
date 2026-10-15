#!/usr/bin/env python3
"""Rebuild GEO offline after acquiring the separate, hash-pinned source archive."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import sys

from geodata_distribution import ROOT, distribution, release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "Resources/GeoData")
    args = parser.parse_args()
    lock = release()
    with distribution(lock) as source:
        subprocess.run([sys.executable, str(source / "script/rebuild_geodata.py"), "--output", str(args.output.resolve())], check=True)
    for asset in lock["assets"]:
        if "sha256:" + hashlib.sha256((args.output / asset["name"]).read_bytes()).hexdigest() != asset["digest"]:
            raise ValueError("GEO 数据与应用锁定清单不一致：" + asset["name"])


if __name__ == "__main__":
    main()

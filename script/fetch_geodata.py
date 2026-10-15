#!/usr/bin/env python3
"""Prepare GEO resources from the separately distributed, hash-pinned inputs."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys

from geodata_distribution import ROOT, distribution, release
from geosite_sources import verify_policy


def prepare(output=None):
    output = Path(output) if output else ROOT / "Resources/GeoData"
    lock = release()
    with distribution(lock) as source:
        inputs = source / lock["source_distribution"]["input_snapshot"]
        policy = source / lock["source_distribution"]["policy"]
        verify_policy(inputs, policy)
        if hashlib.sha256(policy.read_bytes()).hexdigest() != lock["online_update_policy"]["sha256"]:
            raise ValueError("GEO 在线更新策略摘要不一致。")
        if not all((output / a["name"]).is_file() and "sha256:" + hashlib.sha256((output / a["name"]).read_bytes()).hexdigest() == a["digest"] for a in lock["assets"]):
            subprocess.run([sys.executable, str(source / "script/rebuild_geodata.py"), "--output", str(output.resolve())], check=True)
        for asset in lock["assets"]:
            if "sha256:" + hashlib.sha256((output / asset["name"]).read_bytes()).hexdigest() != asset["digest"]:
                raise ValueError("GEO 数据与应用锁定清单不一致：" + asset["name"])
            print("verified", asset["name"], flush=True)
        output.mkdir(parents=True, exist_ok=True)
        temporary = output / "GeoSite-policy.json.partial"
        shutil.copyfile(policy, temporary)
        temporary.replace(output / "GeoSite-policy.json")


if __name__ == "__main__":
    prepare()

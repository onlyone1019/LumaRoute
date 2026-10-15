#!/usr/bin/env python3
"""Rebuild pinned GEO data offline from editable inputs and vendored Go source."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from geosite_sources import verify_policy

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "Resources/GeoData")
    args = parser.parse_args()
    if not shutil.which("go"):
        raise SystemExit("离线重建 GEO 数据需要 Go 1.23 或更新版本；安装后重试。")
    lock = json.loads((ROOT / "Resources/GeoData/release.json").read_text())
    inputs = ROOT / "Resources/GeoData" / lock["input_snapshot"]
    verify_policy(inputs, ROOT / "Resources/GeoData/GeoSite-policy.json")
    manifest = json.loads((inputs / "manifest.json").read_text())
    locked = {a["name"]: a["digest"].removeprefix("sha256:") for a in lock["assets"]}
    if manifest["expected_sha256"] != locked:
        raise SystemExit("GEO 输入快照与应用锁定清单不一致，未写入任何数据。")
    with tempfile.TemporaryDirectory(prefix="lumaroute-geodata-") as folder:
        work = Path(folder)
        env = os.environ.copy()
        env.update(GOPROXY="off", GOSUMDB="off", GOTOOLCHAIN="local", GOMODCACHE=str(work / "empty-module-cache"))
        binary = work / "geodata-snapshot"
        subprocess.run(["go", "build", "-mod=vendor", "-trimpath", "-o", str(binary), "."],
                       cwd=ROOT / "tools/geodata-snapshot", env=env, check=True)
        output = work / "rebuilt"
        subprocess.run([str(binary), "rebuild", str(inputs), str(output)], env=env, check=True)
        for name, expected in locked.items():
            if hashlib.sha256((output / name).read_bytes()).hexdigest() != expected:
                raise SystemExit("GEO 重建校验失败，未写入任何数据：" + name)
        args.output.mkdir(parents=True, exist_ok=True)
        for name in locked:
            temporary = args.output / (name + ".partial")
            shutil.copyfile(output / name, temporary)
            temporary.replace(args.output / name)
    print("已从固定输入离线重建并校验全部 GEO 数据。")


if __name__ == "__main__":
    main()

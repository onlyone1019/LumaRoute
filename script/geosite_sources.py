#!/usr/bin/env python3
"""Verify GEO category overrides against captured, licensed source lines offline."""
import gzip
import hashlib
import json
from pathlib import Path


def categories(snapshot: Path):
    configuration = json.loads((snapshot / "rule-sources.json").read_text())
    for license_file in configuration["licenses"]:
        if hashlib.sha256((snapshot / license_file["file"]).read_bytes()).hexdigest() != license_file["sha256"]:
            raise ValueError("GEO 来源许可证摘要不一致：" + license_file["file"])
    groups = {}
    for source in configuration["sources"]:
        data = (snapshot / source["file"]).read_bytes()
        if hashlib.sha256(data).hexdigest() != source["sha256"]:
            raise ValueError("GEO 来源文件摘要不一致：" + source["file"])
        available = {line.split("#", 1)[0].strip() for line in data.decode().splitlines()}
        for category, selected in source["selected_lines"].items():
            domains = groups.setdefault(category, [])
            for line in selected:
                if line not in available:
                    raise ValueError("GEO 来源中缺少选定规则：" + line)
                if source["syntax"] == "v2ray":
                    # Keep the existing category's unqualified matching semantics.
                    # Source attributes remain available in the captured raw file.
                    value = line.split()[0]
                    if ":" in value:
                        prefix, value = value.split(":", 1)
                        kind = {"domain": "Domain", "full": "Full"}[prefix]
                    else:
                        kind = "Domain"
                elif source["syntax"] == "clash":
                    prefix, value = line.split(",")
                    kind = {"DOMAIN": "Full", "DOMAIN-SUFFIX": "Domain"}[prefix]
                else:
                    raise ValueError("不支持的 GEO 来源语法")
                rule = {"type": kind, "value": value}
                if rule not in domains:
                    domains.append(rule)
    return groups


def verify(snapshot: Path):
    expected = categories(snapshot)
    actual = {group["code"]: group["domains"] for group in json.loads(gzip.decompress((snapshot / "geosite.json.gz").read_bytes()))}
    for code, domains in expected.items():
        if actual.get(code) != domains:
            raise ValueError("GEO 分类与已授权来源不一致：" + code)
    return expected

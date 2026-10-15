"""Reject altered source evidence or category data before packaging GEO assets."""
import gzip
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "script"))
from geodata_distribution import distribution, release
spec = importlib.util.spec_from_file_location("geosite_sources", ROOT / "script/geosite_sources.py")
sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sources)


class GeoSiteSourcesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.snapshot = Path(self.temp.name)
        lock = release()
        with distribution(lock) as source:
            current = source / lock["source_distribution"]["input_snapshot"]
            for name in ("rule-sources.json", "geosite.json.gz"):
                shutil.copyfile(current / name, self.snapshot / name)
            shutil.copytree(current / "sources", self.snapshot / "sources")

    def test_captured_licensed_sources_reproduce_both_categories(self):
        groups = sources.verify(self.snapshot)
        self.assertEqual(set(groups), {"BILIINTL", "SHAREPOINT"})
        self.assertIn({"type": "Full", "value": "p-bstarstatic.akamaized.net"}, groups["BILIINTL"])
        self.assertIn({"type": "Domain", "value": "bilibili.tv"}, groups["BILIINTL"])

    def test_altered_raw_source_is_rejected(self):
        with (self.snapshot / "sources/v2fly-bilibili.txt").open("a") as output:
            output.write("example.invalid\n")
        with self.assertRaisesRegex(ValueError, "来源文件摘要"):
            sources.verify(self.snapshot)

    def test_missing_or_altered_license_is_rejected(self):
        (self.snapshot / "sources/ACL4SSR-LICENSE.txt").write_text("MIT")
        with self.assertRaisesRegex(ValueError, "许可证摘要"):
            sources.verify(self.snapshot)

    def test_selected_rule_must_exist_in_captured_source(self):
        path = self.snapshot / "rule-sources.json"
        config = json.loads(path.read_text())
        config["sources"][0]["selected_lines"]["BILIINTL"].append("unlicensed.invalid")
        path.write_text(json.dumps(config))
        with self.assertRaisesRegex(ValueError, "缺少选定规则"):
            sources.verify(self.snapshot)

    def test_unproven_category_insertion_is_rejected(self):
        path = self.snapshot / "geosite.json.gz"
        groups = json.loads(gzip.decompress(path.read_bytes()))
        next(group for group in groups if group["code"] == "BILIINTL")["domains"].append({"type": "Domain", "value": "unlicensed.invalid"})
        path.write_bytes(gzip.compress(json.dumps(groups).encode(), mtime=0))
        with self.assertRaisesRegex(ValueError, "分类与已授权来源不一致"):
            sources.verify(self.snapshot)

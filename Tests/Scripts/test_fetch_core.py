"""Verify locked core downloads without contacting GitHub or using real binaries."""
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("fetch_core", Path(__file__).resolve().parents[2] / "script/fetch_core.py")
fetch_core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch_core)


def sha(payload):
    return hashlib.sha256(payload).hexdigest()


class FetchCoreTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        (self.root / "Resources/Core").mkdir(parents=True)
        self.target = self.root / "Resources/Core/mihomo-arm64"
        self.payload = b"synthetic executable fixture"
        self.compressed = gzip.compress(self.payload, mtime=0)
        self.asset = dict(arch="arm64", name="fixture.gz", url="https://example.invalid/fixture.gz",
                          release_sha256=sha(self.compressed), github_digest="sha256:" + sha(self.compressed),
                          binary_sha256=sha(self.payload))

    def test_cached_binary_requires_no_network(self):
        self.target.write_bytes(self.payload)
        with patch.object(fetch_core, "fetch", side_effect=AssertionError("unexpected network call")):
            fetch_core.install(self.root, self.asset)
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o755)

    def test_download_uses_only_locked_asset_url(self):
        with patch.object(fetch_core, "fetch", return_value=self.compressed) as download:
            fetch_core.install(self.root, self.asset)
        download.assert_called_once_with(self.asset["url"])
        self.assertEqual(self.target.read_bytes(), self.payload)
        self.assertFalse(self.target.with_name(self.target.name + ".partial").exists())

    def test_corrupted_download_preserves_existing_binary(self):
        self.target.write_bytes(b"existing binary")
        with patch.object(fetch_core, "fetch", return_value=b"corrupt compressed data"):
            with self.assertRaisesRegex(RuntimeError, "release checksum mismatch"):
                fetch_core.install(self.root, self.asset)
        self.assertEqual(self.target.read_bytes(), b"existing binary")

    def test_binary_digest_mismatch_is_rejected_before_install(self):
        self.asset["binary_sha256"] = "0" * 64
        with patch.object(fetch_core, "fetch", return_value=self.compressed):
            with self.assertRaisesRegex(RuntimeError, "binary checksum mismatch"):
                fetch_core.install(self.root, self.asset)
        self.assertFalse(self.target.exists())

    def test_main_uses_locked_urls_and_keeps_manifest_unchanged(self):
        assets = []
        for arch, platform in [("arm64", "arm64"), ("x86_64", "amd64-compatible")]:
            name = f"mihomo-darwin-{platform}-{fetch_core.VERSION}.gz"
            assets.append({**self.asset, "arch": arch, "name": name,
                           "url": f"https://github.com/MetaCubeX/mihomo/releases/download/{fetch_core.VERSION}/{name}"})
        lock = self.root / "Resources/Core/release.json"
        original = json.dumps(dict(version=fetch_core.VERSION, repository="MetaCubeX/mihomo", assets=assets))
        lock.write_text(original)
        with patch.object(fetch_core, "fetch", return_value=self.compressed) as download:
            fetch_core.main(self.root)
        self.assertEqual([call.args[0] for call in download.call_args_list], [asset["url"] for asset in assets])
        self.assertEqual(lock.read_text(), original)
        with patch.object(fetch_core, "fetch", side_effect=AssertionError("unexpected release API call")):
            fetch_core.main(self.root)

    def test_inconsistent_lock_is_rejected_without_network(self):
        self.asset["github_digest"] = "sha256:" + "0" * 64
        with patch.object(fetch_core, "fetch", side_effect=AssertionError("unexpected network call")):
            with self.assertRaisesRegex(RuntimeError, "Inconsistent locked release digest"):
                fetch_core.install(self.root, self.asset)


if __name__ == "__main__":
    unittest.main()

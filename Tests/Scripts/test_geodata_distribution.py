"""Exercise separate GEO acquisition, integrity and extraction boundaries."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.request import Request

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "script"))
from geodata_distribution import SourceRedirect, distribution


def archive(entries):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w:gz") as stream:
        for name, content in entries:
            info = tarfile.TarInfo(name)
            info.size = len(content)
            stream.addfile(info, io.BytesIO(content))
    return data.getvalue()


class GeoDataDistributionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.cache = Path(temporary.name)
        self.env = patch.dict(os.environ, {"GH_TOKEN": "", "GITHUB_TOKEN": "", "LUMAROUTE_GEO_SOURCE_ARCHIVE": ""})
        self.env.start()
        self.addCleanup(self.env.stop)

    def lock(self, data, url="https://example.invalid/geo.tar.gz"):
        return {"source_distribution": {"url": url, "api_url": url, "sha256": hashlib.sha256(data).hexdigest()}}

    def seed(self, data):
        path = self.cache / (hashlib.sha256(data).hexdigest() + ".tar.gz")
        path.write_bytes(data)
        return self.lock(data)

    def test_download_then_offline_reuse_without_retaining_extracted_inputs(self):
        data = archive([("inputs/test.json", b"approved")])
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        lock = self.lock(data, "http://127.0.0.1:%d/geo.tar.gz" % server.server_port)
        try:
            with distribution(lock, self.cache) as root:
                self.assertEqual((root / "inputs/test.json").read_bytes(), b"approved")
                (root / "injected.py").write_text("untrusted")
            self.assertFalse(root.exists())
            with distribution(lock, self.cache) as root:
                self.assertFalse((root / "injected.py").exists())
            self.assertEqual(requests, ["/geo.tar.gz"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_corrupt_cached_archive_is_rejected_before_extraction(self):
        data = archive([("input.json", b"approved")])
        lock = self.seed(data)
        next(self.cache.glob("*.tar.gz")).write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "摘要不一致"):
            with distribution(lock, self.cache):
                self.fail("Corrupt archive must not be opened")
        self.assertFalse(any(self.cache.glob("verified-*")))

    def test_parent_absolute_and_duplicate_archive_paths_are_rejected(self):
        for entries in ([('../escaped', b'x')], [('/escaped', b'x')], [('same', b'a'), ('same', b'b')]):
            with self.subTest(entries=entries):
                lock = self.seed(archive(entries))
                with self.assertRaisesRegex(ValueError, "不安全"):
                    with distribution(lock, self.cache):
                        self.fail("Unsafe archive must not be opened")
        self.assertFalse((self.cache.parent / "escaped").exists())

    def test_local_archive_override_is_verified(self):
        data = archive([("input.json", b"approved")])
        path = self.cache / "downloaded.tar.gz"
        path.write_bytes(data)
        with patch.dict(os.environ, {"LUMAROUTE_GEO_SOURCE_ARCHIVE": str(path)}):
            with distribution(self.lock(data), self.cache) as root:
                self.assertEqual((root / "input.json").read_bytes(), b"approved")

    def test_private_token_is_never_sent_to_non_github_source(self):
        with patch.dict(os.environ, {"GH_TOKEN": "test-token"}):
            with self.assertRaisesRegex(ValueError, "GitHub 官方 API"):
                with distribution(self.lock(b'irrelevant'), self.cache):
                    self.fail("Credentials must not leave GitHub")

    def test_redirect_removes_authorization_when_origin_changes(self):
        req = Request("https://api.github.com/asset", headers={"Authorization": "Bearer test-token"})
        redirected = SourceRedirect().redirect_request(req, None, 302, "Found", {}, "https://release-assets.githubusercontent.com/file")
        self.assertIsNone(redirected.get_header("Authorization"))
        downgraded = SourceRedirect().redirect_request(req, None, 302, "Found", {}, "http://api.github.com/file")
        self.assertIsNone(downgraded.get_header("Authorization"))

#!/usr/bin/env python3
"""Open the hash-pinned, separately distributed GEO source archive."""
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[1]


def release():
    return json.loads((ROOT / "Resources/GeoData/release.json").read_text())


class SourceRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected and urlsplit(req.full_url)[:2] != urlsplit(newurl)[:2]:
            redirected.remove_header("Authorization")
        return redirected


def archive_path(lock, cache):
    source = lock["source_distribution"]
    override = os.environ.get("LUMAROUTE_GEO_SOURCE_ARCHIVE")
    archive = Path(override).expanduser() if override else cache / (source["sha256"] + ".tar.gz")
    if not archive.is_file():
        if override:
            raise ValueError("指定的 GEO 独立源码附件不存在。")
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        url = source["api_url"] if token else source["url"]
        headers = {"Accept": "application/octet-stream", "User-Agent": "LumaRoute-GEO-build"}
        if token:
            if urlsplit(url).scheme != "https" or urlsplit(url).netloc != "api.github.com":
                raise ValueError("GEO 私有附件凭据只允许发送至 GitHub 官方 API。")
            headers["Authorization"] = "Bearer " + token
        with tempfile.NamedTemporaryFile(dir=cache, suffix=".partial") as temporary:
            try:
                with build_opener(SourceRedirect()).open(Request(url, headers=headers), timeout=60) as response:
                    shutil.copyfileobj(response, temporary)
            except HTTPError as error:
                if error.code in (401, 403, 404):
                    raise ValueError("无法取得 GEO 附件；私有仓库请提供 GH_TOKEN，或用 LUMAROUTE_GEO_SOURCE_ARCHIVE 指定已下载附件。") from None
                raise
            temporary.flush()
            if hashlib.sha256(Path(temporary.name).read_bytes()).hexdigest() != source["sha256"]:
                raise ValueError("GEO 独立源码附件摘要不一致，未解包或执行。")
            shutil.copyfile(temporary.name, archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != source["sha256"]:
        raise ValueError("GEO 独立源码附件摘要不一致，未解包或执行。")
    return archive


@contextmanager
def distribution(lock=None, cache=None):
    lock = release() if lock is None else lock
    cache = Path(cache or os.environ.get("LUMAROUTE_GEO_CACHE", ROOT / "work/geodata-cache"))
    cache.mkdir(parents=True, exist_ok=True)
    archive = archive_path(lock, cache)
    # Extract afresh: a modified or extra cached script must never be executed.
    with tempfile.TemporaryDirectory(prefix="verified-", dir=cache) as folder:
        root = Path(folder)
        with tarfile.open(archive) as stream:
            members = stream.getmembers()
            if sum(m.size for m in members) > 128 * 1024 * 1024:
                raise ValueError("GEO 附件解包大小超限。")
            seen = set()
            for member in members:
                path = PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts or not member.isfile() or member.name in seen:
                    raise ValueError("GEO 附件含不安全的路径、链接或重复文件。")
                seen.add(member.name)
                target = root.joinpath(*path.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with stream.extractfile(member) as incoming, target.open("wb") as outgoing:
                    shutil.copyfileobj(incoming, outgoing)
        yield root

#!/usr/bin/env python3
"""Prefetch pinned application packages; elm make still verifies/builds them.

GitHub's zipball redirect can fail before reaching codeload. Use the equivalent
legacy.zip URL first, retaining the official registry's SHA-1 check. Existing
Elm caches need no extra marker and are left intact. Requires Python 3 and curl.
"""

import errno
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import zipfile


MAX_ARCHIVE = 16 * 1024 * 1024
MAX_EXPANDED = 64 * 1024 * 1024
MAX_ENTRIES = 10000
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+"
PACKAGE = r"[A-Za-z0-9-]+/[A-Za-z0-9-]+"


def pinned_packages(manifest):
    if manifest.get("type") != "application":
        raise ValueError("expected an Elm application manifest")
    elm_version = manifest["elm-version"]
    if not re.fullmatch(VERSION, elm_version):
        raise ValueError("expected an exact elm-version")
    packages = {}
    for group in ("dependencies", "test-dependencies"):
        for kind in ("direct", "indirect"):
            for name, version in manifest.get(group, {}).get(kind, {}).items():
                if not re.fullmatch(PACKAGE, name) or not re.fullmatch(VERSION, version):
                    raise ValueError(f"expected an exact package pin: {name} {version}")
                if name in packages and packages[name] != version:
                    raise ValueError(f"conflicting pins for {name}")
                packages[name] = version
    return elm_version, sorted(packages.items())


def archive_urls(url):
    # Only rewrite the known GitHub zipball shape, not arbitrary registry URLs.
    match = re.fullmatch(
        rf"https://github\.com/({PACKAGE})/zipball/({VERSION})/?", url
    )
    if match:
        return [f"https://codeload.github.com/{match[1]}/legacy.zip/{match[2]}", url]
    if not url.startswith("https://"):
        raise ValueError("package archive URL must use HTTPS")
    return [url]


def download(url, destination, limit):
    # curl handles proxies/CA settings used by CI. Disable ~/.curlrc, constrain
    # redirects to HTTPS, bound bytes and both per-attempt and total wall time.
    subprocess.run(
        ["curl", "-q", "--fail", "--silent", "--show-error", "--location",
         "--proto", "=https", "--proto-redir", "=https",
         "--connect-timeout", "10", "--max-time", "45",
         "--retry", "2", "--retry-delay", "1", "--max-filesize", str(limit),
         "--output", str(destination), url],
        check=True, timeout=150, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if destination.stat().st_size > limit:
        raise ValueError(f"download exceeds {limit} bytes: {url}")


def extract_package(archive, destination, name, version):
    """Validate all paths/types/sizes before extracting into a private directory."""
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if not entries or len(entries) > MAX_ENTRIES:
            raise ValueError("empty archive or too many ZIP entries")
        seen, roots = set(), set()
        total = 0
        for entry in entries:
            raw = entry.orig_filename
            parts = raw.removesuffix("/").split("/")
            if (any(p in ("", ".", "..") for p in parts)
                    or any(c in raw for c in ("\\", "\x00", ":"))):
                raise ValueError(f"unsafe ZIP path: {raw!r}")
            key = "/".join(parts).casefold()
            if key in seen:
                raise ValueError(f"duplicate ZIP path: {raw!r}")
            seen.add(key)
            roots.add(parts[0])
            mode = stat.S_IFMT(entry.external_attr >> 16)
            expected = stat.S_IFDIR if entry.is_dir() else stat.S_IFREG
            if mode not in (0, expected):
                raise ValueError(f"unsupported ZIP entry type: {raw!r}")
            total += entry.file_size
            if entry.file_size > MAX_ARCHIVE or total > MAX_EXPANDED:
                raise ValueError("expanded ZIP exceeds size limit")
        if len(roots) != 1:
            raise ValueError("expected one package archive root")
        for entry in entries:
            target = destination.joinpath(*entry.filename.rstrip("/").split("/"))
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                # Full reads verify ZIP CRCs; limits above bound memory usage.
                with source.open(entry) as stream:
                    data = stream.read(MAX_ARCHIVE + 1)
                if len(data) != entry.file_size:
                    raise ValueError("ZIP entry size mismatch")
                with target.open("xb") as output:
                    output.write(data)
    root = destination / roots.pop()
    manifest = json.loads((root / "elm.json").read_text(encoding="utf-8"))
    if (manifest.get("type") != "package" or manifest.get("name") != name
            or manifest.get("version") != version or not (root / "src").is_dir()):
        raise ValueError(f"archive does not contain {name} {version}")
    return root


def cached(path):
    # Compatible with packages installed by Elm itself, including artifacts.dat.
    return (path / "elm.json").is_file() and (path / "src").is_dir()


def prefetch(manifest_path, elm_home):
    elm_version, packages = pinned_packages(json.loads(manifest_path.read_text()))
    cache = elm_home / elm_version / "packages"
    for name, version in packages:
        target = cache / name / version
        if cached(target):
            print(f"elm-prefetch: cached {name} {version}", flush=True)
            continue
        if target.exists():
            raise ValueError(f"incomplete Elm cache entry: {target}; remove it and retry")
        target.parent.mkdir(parents=True, exist_ok=True)
        # Same filesystem as target: readers see either no package or all files.
        with tempfile.TemporaryDirectory(prefix=f".{version}-", dir=target.parent) as tmp:
            stage = Path(tmp)
            metadata = stage / "endpoint.json"
            download(f"https://package.elm-lang.org/packages/{name}/{version}/endpoint.json",
                     metadata, 64 * 1024)
            endpoint = json.loads(metadata.read_text(encoding="utf-8"))
            expected = endpoint["hash"]
            if not re.fullmatch(r"[0-9a-f]{40}", expected):
                raise ValueError(f"invalid registry archive hash for {name} {version}")
            archive = stage / "package.zip"
            urls = archive_urls(endpoint["url"])
            for index, url in enumerate(urls):
                print(f"elm-prefetch: downloading {url}", flush=True)
                try:
                    download(url, archive, MAX_ARCHIVE)
                    break
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                    if index == len(urls) - 1:
                        raise
                    print("elm-prefetch: codeload failed; retrying registry URL", file=sys.stderr)
            actual = hashlib.sha1(archive.read_bytes()).hexdigest()
            if actual != expected:
                raise ValueError(f"archive hash mismatch for {name} {version}: "
                                 f"expected {expected}, got {actual}")
            root = extract_package(archive, stage / "unpacked", name, version)
            try:
                root.rename(target)
            except OSError as error:
                # Another prefetch may have published the same complete pin.
                if error.errno not in (errno.EEXIST, errno.ENOTEMPTY) or not cached(target):
                    raise
            print(f"elm-prefetch: verified {name} {version} SHA1 {actual}", flush=True)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: prefetch-elm.py path/to/elm.json")
    try:
        prefetch(Path(sys.argv[1]), Path(os.environ.get("ELM_HOME", str(Path.home() / ".elm"))))
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile,
            NotImplementedError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"elm-prefetch: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode(errors="replace"), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

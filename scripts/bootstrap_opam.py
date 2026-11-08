"""Seed setup-ocaml v3.9.1's tool cache through GitHub's release asset API.

Keep selection, cache layout and signing key in sync with the workflow's pinned
setup-ocaml SHA. This only installs opam; it never initializes an opam root.
"""

import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


API = "https://api.github.com/repos/ocaml/opam/releases"
KEY_URL = "https://opam.ocaml.org/opam-dev-pubkey.pgp"
FINGERPRINT = "92C526AE50DF39470EB2911BED4CF1CA67CBAA92"
ALLOWED_HOSTS = {"api.github.com", "github.com", "release-assets.githubusercontent.com",
                 "objects.githubusercontent.com", "opam.ocaml.org"}
BINARY_LIMIT = 64 * 1024 * 1024
SMALL_LIMIT = 1024 * 1024
METADATA_LIMIT = 16 * 1024 * 1024
ATTEMPTS = 3
SOCKET_TIMEOUT = 30
DOWNLOAD_TIMEOUT = 120


class TransportError(RuntimeError):
    """Only transport failures permit retries or the browser-route fallback."""


def checked_url(url):
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != "https" or parsed.hostname not in ALLOWED_HOSTS
            or parsed.username is not None or parsed.password is not None
            or parsed.port not in (None, 443) or parsed.fragment):
        raise ValueError("Untrusted download URL")
    return parsed


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        source, target = checked_url(req.full_url), checked_url(newurl)
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None and (source.netloc != target.netloc
                                       or target.hostname != "api.github.com"):
            redirected.remove_header("Authorization")
        return redirected


def download(url, limit, token="", accept="application/octet-stream"):
    host = checked_url(url).hostname
    headers = {"Accept": accept, "User-Agent": "tesl-opam-bootstrap",
               "X-GitHub-Api-Version": "2022-11-28"}
    if token and host == "api.github.com":
        # Unredirected headers never propagate to a redirect, even on one host.
        auth = {"Authorization": f"Bearer {token}"}
    else:
        auth = {}
    opener = urllib.request.build_opener(SafeRedirect())
    for attempt in range(ATTEMPTS):
        request = urllib.request.Request(url, headers=headers)
        for name, value in auth.items():
            request.add_unredirected_header(name, value)
        try:
            deadline = time.monotonic() + DOWNLOAD_TIMEOUT
            with opener.open(request, timeout=SOCKET_TIMEOUT) as response:
                size = response.headers.get("Content-Length")
                if size is not None and (not size.isdecimal() or int(size) > limit):
                    raise ValueError("Invalid or oversized download Content-Length")
                data = bytearray()
                while True:
                    if time.monotonic() >= deadline:
                        raise TransportError("Download deadline exceeded")
                    chunk = response.read1(min(64 * 1024, limit + 1 - len(data)))
                    if not chunk:
                        break
                    data.extend(chunk)
                    if len(data) > limit:
                        raise ValueError("Download exceeds size limit")
                if size is not None and len(data) != int(size):
                    raise TransportError("Truncated download")
                return bytes(data)
        except urllib.error.HTTPError as error:
            if error.code not in (408, 429) and not 500 <= error.code <= 599:
                raise ValueError(f"Download rejected: HTTP {error.code}") from None
        except (urllib.error.URLError, TimeoutError, ConnectionError,
                http.client.HTTPException, TransportError):
            pass
        if attempt + 1 < ATTEMPTS:
            print(f"Transport failure from {host}; retry {attempt + 2}/{ATTEMPTS}", flush=True)
            time.sleep(2 ** attempt)
    # Do not print exceptions/redirect URLs: they can contain credentials.
    raise TransportError(f"Download failed after {ATTEMPTS} attempts from {host}")


def list_releases(token):
    releases = []
    # Bound pagination; fail rather than select from an incomplete inventory.
    for page in range(1, 11):
        batch = json.loads(download(f"{API}?per_page=100&page={page}", METADATA_LIMIT,
                                    token, "application/vnd.github+json"))
        if not isinstance(batch, list) or not all(isinstance(r, dict) for r in batch):
            raise ValueError("Invalid release inventory")
        releases.extend(batch)
        if len(batch) < 100:
            return releases
    raise ValueError("Release inventory exceeds pagination limit")


def runner_target(runner_os, runner_arch):
    systems = {"Linux": "linux", "macOS": "macos", "Windows": "windows"}
    architectures = {"X64": "x86_64", "ARM64": "arm64"}
    if runner_os not in systems or runner_arch not in architectures:
        raise ValueError("Unsupported RUNNER_OS/RUNNER_ARCH")
    return systems[runner_os], architectures[runner_arch]


def stable_version(tag):
    # Stable semver only; normalize v/leading zeros/build metadata as tool-cache
    # does. Paths use the normalized version, never an unchecked API tag.
    match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)(?:\+[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)?", tag, re.ASCII)
    return tuple(map(int, match.groups())) if match else None


def validate_asset(asset, tag):
    name, asset_id = asset.get("name", ""), asset.get("id")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", name):
        raise ValueError("Malformed release asset name")
    if type(asset_id) is not int or asset_id <= 0:
        raise ValueError("Malformed release asset ID")
    if asset.get("url") != f"{API}/assets/{asset_id}":
        raise ValueError("Unexpected release asset API route")
    expected = f"https://github.com/ocaml/opam/releases/download/{tag}/{name}"
    if asset.get("browser_download_url") != expected:
        raise ValueError("Unexpected release asset browser route")
    digest = asset.get("digest")
    if digest is not None and not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("Malformed release asset SHA256")


def select_release(releases, system, arch):
    if system not in {"linux", "macos", "windows"} or arch not in {"x86_64", "arm64"}:
        raise ValueError("Unsupported opam platform")
    suffix = f"{arch}-{system}" + (".exe" if system == "windows" else "")
    candidates = []
    for release in releases:
        tag = release.get("tag_name", "")
        version = stable_version(tag)
        if version is not None and version < (2, 7, 0):
            candidates.append((version, tag, release))
    for version, tag, release in sorted(candidates, key=lambda r: r[0], reverse=True):
        assets = release.get("assets", [])
        binary = next((a for a in assets if a.get("name", "").endswith(suffix)), None)
        if binary is None:
            continue
        signature = next((a for a in assets if a.get("name") == binary["name"] + ".sig"), None)
        if signature is None:
            raise ValueError("Selected opam release has no signature")
        for asset in (binary, signature):
            validate_asset(asset, tag)
        return ".".join(map(str, version)), binary, signature
    raise ValueError("No stable opam release <2.7.0 supports this platform")


def download_asset(asset, limit, token):
    print(f"Downloading {asset['name']} through the GitHub release asset API", flush=True)
    try:
        data = download(asset["url"], limit, token)
    except TransportError:
        print("Asset API transport failed; trying official browser route", flush=True)
        data = download(asset["browser_download_url"], limit)
    if not data:
        raise ValueError("Empty release asset")
    digest = asset.get("digest")
    if digest is not None and "sha256:" + hashlib.sha256(data).hexdigest() != digest:
        raise ValueError("Release asset SHA256 mismatch")
    if digest is not None:
        print(f"Verified release asset {digest}", flush=True)
    return data


def gpg_path(path, system):
    value = str(path)
    if system != "windows":
        return value
    if not re.match(r"^[A-Za-z]:[\\/]", value):
        raise ValueError("GPG requires an absolute Windows drive path")
    return "/" + value[0].lower() + "/" + value[3:].replace("\\", "/")


def verify_signature(binary, signature, key, system):
    gpg = "C:/msys64/usr/bin/gpg.exe" if system == "windows" else "gpg"
    with tempfile.TemporaryDirectory(prefix="gpg-", dir=binary.parent) as home:
        command = [gpg, "--no-options", "--batch", "--homedir", gpg_path(home, system),
                   "--no-auto-key-retrieve"]
        for args in (["--import", gpg_path(key, system)],
                     ["--status-fd", "1", "--verify", gpg_path(signature, system), gpg_path(binary, system)]):
            result = subprocess.run(command + args, capture_output=True, text=True, timeout=30)
            if result.returncode != 0:
                raise ValueError("GPG import/signature verification failed")
        fingerprints = [line.split()[-1] for line in result.stdout.splitlines()
                        if line.startswith("[GNUPG:] VALIDSIG ")]
        if fingerprints != [FINGERPRINT]:
            raise ValueError("Opam signature does not match expected primary fingerprint")
    print(f"Verified opam signature with key {FINGERPRINT}", flush=True)


def install(cache, release, system, arch, token):
    version, binary_asset, signature_asset = release
    if stable_version(version) is None or version != ".".join(map(str, stable_version(version))):
        raise ValueError("Invalid cache version")
    if system not in {"linux", "macos", "windows"} or arch not in {"x86_64", "arm64"}:
        raise ValueError("Invalid cache platform")
    parent = cache / "opam" / version
    directory, marker = parent / arch, parent / (arch + ".complete")
    binary = directory / ("opam.exe" if system == "windows" else "opam")
    for path in (cache / "opam", parent, directory, binary, marker):
        if path.is_symlink():
            raise ValueError("Symlink in opam tool cache")
    # Trust complete existing tool caches, just as setup-ocaml does. A marker
    # alone or a binary without its marker is not a usable cache entry.
    if (marker.is_file() and binary.is_file() and binary.stat().st_size > 0
            and (system == "windows" or os.access(binary, os.X_OK))):
        print(f"Using complete opam {version} tool cache", flush=True)
        return binary
    marker.unlink(missing_ok=True)
    parent.mkdir(parents=True, exist_ok=True)
    # Stage on the same filesystem so os.replace publishes the entire file.
    with tempfile.TemporaryDirectory(prefix=".opam-bootstrap-", dir=parent) as temporary:
        staging = Path(temporary)
        staged_binary, signature, key = (staging / name for name in (binary.name, "opam.sig", "key.pgp"))
        staged_binary.write_bytes(download_asset(binary_asset, BINARY_LIMIT, token))
        signature.write_bytes(download_asset(signature_asset, SMALL_LIMIT, token))
        key.write_bytes(download(KEY_URL, SMALL_LIMIT))
        verify_signature(staged_binary, signature, key, system)
        staged_binary.chmod(0o755)
        with staged_binary.open("rb+") as stream:
            os.fsync(stream.fileno())
        directory.mkdir(exist_ok=True)
        os.replace(staged_binary, binary)
        staged_marker = staging / "complete"
        staged_marker.touch()
        os.replace(staged_marker, marker)
    print(f"Cached verified opam {version} ({system}/{arch})", flush=True)
    return binary


def main():
    system, arch = runner_target(os.environ.get("RUNNER_OS"), os.environ.get("RUNNER_ARCH"))
    cache = Path(os.environ["RUNNER_TOOL_CACHE"])
    if not cache.is_absolute():
        raise ValueError("RUNNER_TOOL_CACHE must be absolute")
    token = os.environ.get("GH_TOKEN", "")
    release = select_release(list_releases(token), system, arch)
    install(cache, release, system, arch, token)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, KeyError, subprocess.SubprocessError) as error:
        # Avoid raw network/subprocess messages, which may include secrets.
        detail = str(error) if isinstance(error, (ValueError, TransportError)) else type(error).__name__
        print(f"Opam bootstrap failed: {detail}; cache not published", file=sys.stderr)
        sys.exit(1)

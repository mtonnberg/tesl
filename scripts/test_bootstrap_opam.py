"""Offline bootstrap contract tests; real download smoke is run separately."""

import hashlib
import io
import json
import os
from pathlib import Path, PureWindowsPath
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.error
import urllib.request

import bootstrap_opam as bootstrap


def asset(name, tag="2.6.1", asset_id=123, data=b"binary"):
    return {"id": asset_id, "name": name,
            "url": f"{bootstrap.API}/assets/{asset_id}",
            "browser_download_url": f"https://github.com/ocaml/opam/releases/download/{tag}/{name}",
            "digest": "sha256:" + hashlib.sha256(data).hexdigest()}


def release(tag="2.6.1", system="linux", arch="x86_64"):
    name = f"opam-{tag}-{arch}-{system}" + (".exe" if system == "windows" else "")
    return {"tag_name": tag, "assets": [asset(name, tag), asset(name + ".sig", tag, 124, b"signature")]}


class ReleaseTests(unittest.TestCase):
    def test_highest_stable_below_cap_with_platform_asset(self):
        releases = [release("2.5.0"), release("2.7.0"), release("2.6.0"),
                    release("2.6.2", "macos"), release("2.6.3-rc1"), release("2.6.1")]
        self.assertEqual(bootstrap.select_release(releases, "linux", "x86_64")[0], "2.6.1")
        self.assertEqual(bootstrap.select_release(releases, "macos", "x86_64")[0], "2.6.2")

    def test_version_normalization_and_malformed_versions(self):
        self.assertEqual(bootstrap.select_release([release("v2.6.1+build.1")], "linux", "x86_64")[0], "2.6.1")
        for tag in ("../../2.6.1", "2.6", "2.6.1/evil", "2.6.1-rc1", "2.7.0", "9.0.0"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                bootstrap.select_release([release(tag)], "linux", "x86_64")

    def test_missing_signature_does_not_downgrade(self):
        newest = release()
        newest["assets"].pop()
        with self.assertRaisesRegex(ValueError, "no signature"):
            bootstrap.select_release([newest, release("2.5.0")], "linux", "x86_64")

    def test_malformed_asset_routes_names_and_digests(self):
        for key, value in (("name", "../../x86_64-linux"), ("id", -1), ("id", True),
                           ("url", "https://evil.test/asset"),
                           ("browser_download_url", "https://github.com/other/opam/asset"),
                           ("digest", "sha256:bad")):
            candidate = release()
            candidate["assets"][0][key] = value
            if key == "name":
                candidate["assets"][1]["name"] = value + ".sig"
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                bootstrap.select_release([candidate], "linux", "x86_64")

    def test_all_runner_targets_and_windows_suffix(self):
        for runner_os, system in (("Linux", "linux"), ("macOS", "macos"), ("Windows", "windows")):
            for runner_arch, arch in (("X64", "x86_64"), ("ARM64", "arm64")):
                self.assertEqual(bootstrap.runner_target(runner_os, runner_arch), (system, arch))
                selected = bootstrap.select_release([release(system=system, arch=arch)], system, arch)
                self.assertEqual(selected[1]["name"].endswith(".exe"), system == "windows")
        for system, arch in (("../linux", "x86_64"), ("linux", "../x86_64")):
            with self.assertRaises(ValueError):
                bootstrap.select_release([], system, arch)
        with self.assertRaises(ValueError):
            bootstrap.runner_target("Linux", "ARM")

    def test_pagination_and_incomplete_inventory(self):
        with patch.object(bootstrap, "download", side_effect=[json.dumps([release()] * 100).encode(), b"[]"]) as fetch:
            self.assertEqual(len(bootstrap.list_releases("secret")), 100)
            self.assertIn("page=2", fetch.call_args.args[0])
        with patch.object(bootstrap, "download", return_value=json.dumps([release()] * 100).encode()) as fetch:
            with self.assertRaisesRegex(ValueError, "pagination"):
                bootstrap.list_releases("")
            self.assertEqual(fetch.call_count, 10)


class Response(io.BytesIO):
    def __init__(self, data, headers=None):
        super().__init__(data)
        self.headers = headers or {}


class DownloadTests(unittest.TestCase):
    def test_api_auth_and_accept_browser_and_key_without_token(self):
        opener = Mock()
        opener.open.side_effect = lambda *a, **k: Response(b"ok")
        with patch.object(bootstrap.urllib.request, "build_opener", return_value=opener):
            for url in (f"{bootstrap.API}/assets/123", bootstrap.KEY_URL,
                        "https://github.com/ocaml/opam/releases/download/2.6.1/opam"):
                self.assertEqual(bootstrap.download(url, 2, "secret"), b"ok")
        requests = [call.args[0] for call in opener.open.call_args_list]
        self.assertEqual(requests[0].get_header("Authorization"), "Bearer secret")
        self.assertEqual(requests[0].get_header("Accept"), "application/octet-stream")
        self.assertTrue(all(r.get_header("Authorization") is None for r in requests[1:]))

    def test_cross_host_redirect_strips_auth_and_forbids_unsafe_routes(self):
        handler = bootstrap.SafeRedirect()
        request = urllib.request.Request(f"{bootstrap.API}/assets/123", headers={"Authorization": "Bearer secret"})
        target = "https://release-assets.githubusercontent.com/github-production-release-asset/123?signature=opaque"
        redirected = handler.redirect_request(request, None, 302, "Found", {}, target)
        self.assertIsNone(redirected.get_header("Authorization"))
        for url in ("http://api.github.com/asset", "https://api.github.com.evil.test/asset",
                    "https://secret@api.github.com/asset", "https://api.github.com:444/asset",
                    "file:///tmp/asset"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                handler.redirect_request(request, None, 302, "Found", {}, url)

    def test_transport_retries_are_bounded_and_do_not_log_token(self):
        opener = Mock()
        opener.open.side_effect = urllib.error.HTTPError(bootstrap.API, 504, "secret", {}, None)
        with patch.object(bootstrap.urllib.request, "build_opener", return_value=opener), \
                patch.object(bootstrap.time, "sleep"), patch("sys.stdout", new_callable=io.StringIO) as output:
            with self.assertRaises(bootstrap.TransportError) as caught:
                bootstrap.download(bootstrap.API, 1024, "secret")
            self.assertEqual(opener.open.call_count, bootstrap.ATTEMPTS)
            self.assertNotIn("secret", output.getvalue() + str(caught.exception))
            self.assertEqual(opener.open.call_args.kwargs["timeout"], bootstrap.SOCKET_TIMEOUT)

    def test_http_permission_errors_are_not_retried(self):
        opener = Mock()
        opener.open.side_effect = urllib.error.HTTPError(bootstrap.API, 403, "secret", {}, None)
        with patch.object(bootstrap.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(ValueError, "HTTP 403"):
                bootstrap.download(bootstrap.API, 1024, "secret")
        self.assertEqual(opener.open.call_count, 1)

    def test_size_limits_truncation_and_deadline(self):
        for data, headers in ((b"abc", {}), (b"a", {"Content-Length": "3"}),
                              (b"a", {"Content-Length": "invalid"})):
            opener = Mock()
            opener.open.return_value = Response(data, headers)
            with patch.object(bootstrap.urllib.request, "build_opener", return_value=opener):
                with self.assertRaises(ValueError):
                    bootstrap.download(bootstrap.API, 2)
            self.assertEqual(opener.open.call_count, 1)
        opener = Mock()
        opener.open.side_effect = lambda *a, **k: Response(b"a", {"Content-Length": "2"})
        with patch.object(bootstrap.urllib.request, "build_opener", return_value=opener), patch.object(bootstrap.time, "sleep"):
            with self.assertRaises(bootstrap.TransportError):
                bootstrap.download(bootstrap.API, 2)
        opener.open.side_effect = lambda *a, **k: Response(b"a")
        with patch.object(bootstrap.urllib.request, "build_opener", return_value=opener), \
                patch.object(bootstrap.time, "sleep"), \
                patch.object(bootstrap.time, "monotonic", side_effect=[0, 121] * bootstrap.ATTEMPTS):
            with self.assertRaises(bootstrap.TransportError):
                bootstrap.download(bootstrap.API, 2)

    def test_api_transport_fallback_but_no_integrity_fallback(self):
        selected = release()["assets"][0]
        with patch.object(bootstrap, "download", side_effect=[bootstrap.TransportError("504"), b"binary"]) as fetch:
            self.assertEqual(bootstrap.download_asset(selected, 100, "secret"), b"binary")
            self.assertEqual(fetch.call_args_list[0].args, (selected["url"], 100, "secret"))
            self.assertEqual(fetch.call_args_list[1].args, (selected["browser_download_url"], 100))
        for failure in (b"tampered", b"", ValueError("HTTP 401")):
            with patch.object(bootstrap, "download", side_effect=[failure]) as fetch:
                with self.assertRaises(ValueError):
                    bootstrap.download_asset(selected, 100, "secret")
                self.assertEqual(fetch.call_count, 1)
        selected["digest"] = None
        with patch.object(bootstrap, "download", return_value=b"binary"):
            self.assertEqual(bootstrap.download_asset(selected, 100, ""), b"binary")


class SignatureTests(unittest.TestCase):
    def test_exit_code_and_primary_fingerprint_required(self):
        good = f"[GNUPG:] VALIDSIG signing-subkey other-fields {bootstrap.FINGERPRINT}\n"
        for code, status, succeeds in ((0, good, True), (1, good, False),
                                       (0, good.replace(bootstrap.FINGERPRINT, "WRONG"), False),
                                       (0, "[GNUPG:] GOODSIG key name\n", False), (0, "", False)):
            with self.subTest(code=code, status=status), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                results = [subprocess.CompletedProcess([], 0, "", ""),
                           subprocess.CompletedProcess([], code, status, "")]
                with patch.object(bootstrap.subprocess, "run", side_effect=results) as run:
                    if succeeds:
                        bootstrap.verify_signature(root / "opam", root / "sig", root / "key", "linux")
                    else:
                        with self.assertRaises(ValueError):
                            bootstrap.verify_signature(root / "opam", root / "sig", root / "key", "linux")
                    self.assertIn("--no-auto-key-retrieve", run.call_args.args[0])
                    self.assertEqual(run.call_args.kwargs["timeout"], 30)
                self.assertEqual(list(root.iterdir()), [])

    def test_key_import_failure_stops_verification(self):
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(bootstrap.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "")) as run:
            root = Path(temporary)
            with self.assertRaises(ValueError):
                bootstrap.verify_signature(root / "opam", root / "sig", root / "key", "linux")
            self.assertEqual(run.call_count, 1)

    def test_windows_gpg_paths_preserve_spaces(self):
        self.assertEqual(bootstrap.gpg_path(r"D:\tool cache\opam.exe", "windows"), "/d/tool cache/opam.exe")
        self.assertEqual(bootstrap.gpg_path("C:/Users/runner/temp", "windows"), "/c/Users/runner/temp")
        for path in ("relative", r"\\server\share\opam", "C:opam"):
            with self.assertRaises(ValueError):
                bootstrap.gpg_path(path, "windows")

    def test_windows_uses_msys_gpg_and_converts_all_data_paths(self):
        root = PureWindowsPath(r"D:\tool cache\staging")
        status = f"[GNUPG:] VALIDSIG subkey fields {bootstrap.FINGERPRINT}\n"
        with patch.object(bootstrap.tempfile, "TemporaryDirectory") as temporary, \
                patch.object(bootstrap.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, status, "")) as run:
            temporary.return_value.__enter__.return_value = str(root / "gpg-home")
            bootstrap.verify_signature(root / "opam.exe", root / "sig", root / "key", "windows")
        for call in run.call_args_list:
            command = call.args[0]
            self.assertEqual(command[0], "C:/msys64/usr/bin/gpg.exe")
            self.assertEqual(command[command.index("--homedir") + 1], "/d/tool cache/staging/gpg-home")
        self.assertEqual(run.call_args_list[0].args[0][-1], "/d/tool cache/staging/key")
        self.assertEqual(run.call_args_list[1].args[0][-2:], ["/d/tool cache/staging/sig", "/d/tool cache/staging/opam.exe"])


class CacheTests(unittest.TestCase):
    def install(self, root, system="linux", arch="x86_64"):
        selected = bootstrap.select_release([release(system=system, arch=arch)], system, arch)
        return bootstrap.install(root, selected, system, arch, "secret")

    def test_publication_follows_verification_and_atomic_binary_replace(self):
        for system in ("linux", "macos", "windows"):
            with self.subTest(system=system), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                marker = root / "opam/2.6.1/x86_64.complete"
                binary = root / "opam/2.6.1/x86_64" / ("opam.exe" if system == "windows" else "opam")
                verified, events = [], []

                def verify(*args):
                    self.assertFalse(marker.exists())
                    self.assertFalse(binary.exists())
                    self.assertEqual(args[0].read_bytes(), b"binary")
                    verified.append(True)

                replace = os.replace

                def publish(source, target):
                    self.assertTrue(verified)
                    self.assertFalse(marker.exists())
                    if target == marker:
                        self.assertEqual(binary.read_bytes(), b"binary")
                    events.append(target)
                    replace(source, target)

                with patch.object(bootstrap, "download_asset", side_effect=[b"binary", b"sig"]), \
                        patch.object(bootstrap, "download", return_value=b"key"), \
                        patch.object(bootstrap, "verify_signature", side_effect=verify), \
                        patch.object(bootstrap.os, "replace", side_effect=publish):
                    self.assertEqual(self.install(root, system), binary)
                self.assertEqual(events, [binary, marker])
                self.assertTrue(marker.is_file())
                self.assertEqual(list(binary.parent.parent.glob(".opam-bootstrap-*")), [])

    def test_partial_caches_are_rebuilt_complete_cache_is_trusted(self):
        for state in ("binary-only", "marker-only", "empty-binary", "complete"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                binary = root / "opam/2.6.1/x86_64/opam"
                marker = binary.parent.with_suffix(".complete")
                binary.parent.mkdir(parents=True)
                if state != "marker-only":
                    binary.write_bytes(b"" if state == "empty-binary" else b"existing")
                    binary.chmod(0o755)
                if state != "binary-only":
                    marker.touch()
                with patch.object(bootstrap, "download_asset", side_effect=[b"binary", b"sig"]) as fetch, \
                        patch.object(bootstrap, "download", return_value=b"key"), \
                        patch.object(bootstrap, "verify_signature") as verify:
                    self.install(root)
                self.assertEqual(fetch.call_count, 0 if state == "complete" else 2)
                self.assertEqual(verify.call_count, 0 if state == "complete" else 1)
                self.assertEqual(binary.read_bytes(), b"existing" if state == "complete" else b"binary")

    def test_hash_signature_or_publication_failure_never_marks_complete(self):
        for failure in ("hash", "signature", "binary-replace", "marker-replace"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                marker = root / "opam/2.6.1/x86_64.complete"
                replace = os.replace

                def publish(source, target):
                    if failure == "binary-replace" or (failure == "marker-replace" and target == marker):
                        raise OSError("interrupted publication")
                    replace(source, target)

                with patch.object(bootstrap, "download_asset", side_effect=ValueError("hash") if failure == "hash" else [b"binary", b"sig"]), \
                        patch.object(bootstrap, "download", return_value=b"key"), \
                        patch.object(bootstrap, "verify_signature", side_effect=ValueError("signature") if failure == "signature" else None), \
                        patch.object(bootstrap.os, "replace", side_effect=publish):
                    with self.assertRaises((ValueError, OSError)):
                        self.install(root)
                self.assertFalse(marker.exists())
                self.assertEqual(list(marker.parent.glob(".opam-bootstrap-*")), [])


if __name__ == "__main__":
    unittest.main()

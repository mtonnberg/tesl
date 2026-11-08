"""Network-free tests for package integrity and complete cache publication."""

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile


SPEC = importlib.util.spec_from_file_location(
    "elm_prefetch", Path(__file__).resolve().parents[1] / "playground" / "prefetch-elm.py"
)
prefetch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prefetch)
URL = "https://github.com/elm/browser/zipball/1.0.2/"
DIRECT = "https://codeload.github.com/elm/browser/legacy.zip/1.0.2"


def archive(extra=(), version="1.0.2", source=True):
    output = io.BytesIO()
    with warnings.catch_warnings(), zipfile.ZipFile(output, "w") as zipped:
        warnings.simplefilter("ignore", UserWarning)  # Intentional duplicate fixture.
        zipped.writestr("elm-browser-abc/elm.json", json.dumps({
            "type": "package", "name": "elm/browser", "version": version,
        }))
        if source:
            zipped.writestr("elm-browser-abc/src/Browser.elm", "module Browser exposing (..)")
        for name, data in extra:
            zipped.writestr(name, data)
    return output.getvalue()


class PrefetchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.manifest = self.home / "elm.json"
        self.manifest.write_text(json.dumps({
            "type": "application", "elm-version": "0.19.1",
            "dependencies": {"direct": {"elm/browser": "1.0.2"}, "indirect": {}},
            "test-dependencies": {"direct": {}, "indirect": {}},
        }))
        self.target = self.home / "0.19.1/packages/elm/browser/1.0.2"
        self.data = archive()
        self.hash = None
        self.calls = []
        self.fallback = False

    def download(self, url, destination, limit):
        self.calls.append(url)
        self.assertFalse(self.target.exists(), "package published before validation")
        if url.endswith("endpoint.json"):
            destination.write_text(json.dumps({
                "url": URL, "hash": self.hash or hashlib.sha1(self.data).hexdigest(),
            }))
        elif url == DIRECT and self.fallback:
            destination.write_bytes(b"partial failed download")
            raise subprocess.CalledProcessError(22, ["curl"])
        else:
            destination.write_bytes(self.data)

    def run_prefetch(self):
        with patch.object(prefetch, "download", side_effect=self.download), \
                patch("sys.stdout", new_callable=io.StringIO), \
                patch("sys.stderr", new_callable=io.StringIO):
            prefetch.prefetch(self.manifest, self.home)

    def assert_unpublished(self):
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.target.parent.iterdir()), [])

    def test_cold_cache_then_warm_cache_without_network(self):
        self.run_prefetch()
        self.assertEqual(self.calls[-1], DIRECT)
        self.assertEqual((self.target / "src/Browser.elm").read_text(),
                         "module Browser exposing (..)")
        (self.target / "artifacts.dat").write_bytes(b"existing Elm build data")
        with patch.object(prefetch, "download", side_effect=AssertionError("network on warm cache")):
            prefetch.prefetch(self.manifest, self.home)
        self.assertEqual((self.target / "artifacts.dat").read_bytes(), b"existing Elm build data")
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_official_url_fallback(self):
        self.fallback = True
        self.run_prefetch()
        self.assertEqual(self.calls[-2:], [DIRECT, URL])
        self.assertTrue(prefetch.cached(self.target))

    def test_only_known_urls_rewritten(self):
        self.assertEqual(prefetch.archive_urls(URL), [DIRECT, URL])
        other = "https://example.org/source.zip"
        self.assertEqual(prefetch.archive_urls(other), [other])
        with self.assertRaises(ValueError):
            prefetch.archive_urls("http://github.com/elm/browser/zipball/1.0.2/")

    def test_hash_mismatch_before_extraction(self):
        self.hash = "0" * 40
        with patch.object(prefetch, "extract_package") as extract:
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                self.run_prefetch()
            extract.assert_not_called()
        self.assert_unpublished()
        self.assertNotIn(URL, self.calls)  # Integrity failure must not trigger fallback.

    def test_bad_zip_not_published(self):
        self.data = b"not a zip but matches the advertised hash"
        with self.assertRaises(zipfile.BadZipFile):
            self.run_prefetch()
        self.assert_unpublished()

    def test_unsafe_archive_paths_and_types(self):
        symlink = zipfile.ZipInfo("elm-browser-abc/src/link")
        symlink.create_system = 3
        symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
        for path in ("../escape", "/absolute", "elm-browser-abc/../escape",
                     "elm-browser-abc/src/./alias", "elm-browser-abc/src\\alias",
                     "elm-browser-abc/src//alias", "C:/escape",
                     "elm-browser-abc/src/Browser.elm", "other-root/file", symlink):
            with self.subTest(path=path):
                self.data = archive([(path, "bad")])
                with self.assertRaises(ValueError):
                    self.run_prefetch()
                self.assert_unpublished()

    def test_file_directory_collision_not_published(self):
        self.data = archive([("elm-browser-abc/src/Browser.elm/child", "bad")])
        with self.assertRaises(OSError):
            self.run_prefetch()
        self.assert_unpublished()

    def test_expanded_size_and_entry_limits(self):
        for setting, limit in (("MAX_ARCHIVE", 10), ("MAX_EXPANDED", 10), ("MAX_ENTRIES", 1)):
            with self.subTest(setting=setting), patch.object(prefetch, setting, limit):
                with self.assertRaises(ValueError):
                    self.run_prefetch()
                self.assert_unpublished()

    def test_wrong_package_identity_not_published(self):
        self.data = archive(version="9.9.9")
        with self.assertRaisesRegex(ValueError, "does not contain"):
            self.run_prefetch()
        self.assert_unpublished()

    def test_missing_source_not_published(self):
        self.data = archive(source=False)
        with self.assertRaisesRegex(ValueError, "does not contain"):
            self.run_prefetch()
        self.assert_unpublished()

    def test_bad_crc_not_published(self):
        self.data = self.data.replace(b"1.0.2", b"9.9.9")
        with self.assertRaises(zipfile.BadZipFile):
            self.run_prefetch()
        self.assert_unpublished()

    def test_failed_publication_cleans_staging(self):
        with patch.object(Path, "rename", side_effect=OSError("publication failed")):
            with self.assertRaisesRegex(OSError, "publication failed"):
                self.run_prefetch()
        self.assert_unpublished()

    def test_download_failure_leaves_no_cache_entry(self):
        with patch.object(prefetch, "download", side_effect=subprocess.TimeoutExpired("curl", 150)):
            with self.assertRaises(subprocess.TimeoutExpired):
                prefetch.prefetch(self.manifest, self.home)
        self.assert_unpublished()

    def test_incomplete_existing_cache_fails_without_overwrite(self):
        self.target.mkdir(parents=True)
        marker = self.target / "partial"
        marker.write_text("keep")
        with self.assertRaisesRegex(ValueError, "incomplete Elm cache"):
            self.run_prefetch()
        self.assertEqual(marker.read_text(), "keep")

    def test_all_dependency_groups_and_exact_pins(self):
        manifest = json.loads(self.manifest.read_text())
        manifest["dependencies"]["indirect"] = {"elm/core": "1.0.5"}
        manifest["test-dependencies"] = {
            "direct": {"elm-explorations/test": "2.2.0"},
            "indirect": {"elm/random": "1.0.0", "elm/core": "1.0.5"},
        }
        version, packages = prefetch.pinned_packages(manifest)
        self.assertEqual(version, "0.19.1")
        self.assertEqual(dict(packages), {
            "elm/browser": "1.0.2", "elm/core": "1.0.5",
            "elm-explorations/test": "2.2.0", "elm/random": "1.0.0",
        })
        manifest["test-dependencies"]["indirect"]["elm/core"] = "1.0.4"
        with self.assertRaisesRegex(ValueError, "conflicting"):
            prefetch.pinned_packages(manifest)
        manifest["test-dependencies"]["indirect"]["elm/core"] = "1.0.0 <= v < 2.0.0"
        with self.assertRaisesRegex(ValueError, "exact package pin"):
            prefetch.pinned_packages(manifest)

    def test_download_bounds_and_https(self):
        output = self.home / "download"
        output.write_bytes(b"oversized")
        with patch.object(prefetch.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "exceeds"):
                prefetch.download(DIRECT, output, 1)
        args, kwargs = run.call_args
        command = args[0]
        for flag, value in (("--retry", "2"), ("--max-time", "45"),
                            ("--connect-timeout", "10"), ("--max-filesize", "1"),
                            ("--proto", "=https"), ("--proto-redir", "=https")):
            self.assertEqual(command[command.index(flag) + 1], value)
        self.assertEqual(kwargs["timeout"], 150)
        self.assertTrue(kwargs["check"])


class ColdCacheIntegrationTest(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("TESL_ELM_PREFETCH_NETWORK_TEST") == "1",
                         "opt-in: official registry, codeload and elm make")
    def test_fresh_elm_home_and_fresh_elm_stuff(self):
        # No pre-existing project artifacts or Elm registry can mask missing packages.
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="elm-cold-") as tmp:
            work = Path(tmp)
            project = work / "project"
            shutil.copytree(root / "playground/elm", project,
                            ignore=shutil.ignore_patterns("elm-stuff"))
            home = work / "elm-home"
            prefetch.prefetch(project / "elm.json", home)
            subprocess.run(
                ["elm", "make", "src/Main.elm", "--optimize",
                 "--output=" + str(work / "playground-elm.js")],
                cwd=project, env={**os.environ, "ELM_HOME": str(home)},
                check=True, timeout=180,
            )
            self.assertGreater((work / "playground-elm.js").stat().st_size, 0)


if __name__ == "__main__":
    unittest.main()

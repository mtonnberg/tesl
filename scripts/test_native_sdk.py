"""Source verification and build-environment contract for the native Go SDK."""

import base64
from contextlib import contextmanager
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import native_sdk as sdk


@contextmanager
def fixture():
    with tempfile.TemporaryDirectory(prefix="tesl-sdk-test-") as temporary:
        root = Path(temporary)
        archive = root / "source.tar.gz"
        with tarfile.open(archive, "w:gz") as stream:
            for name, data in (("go/VERSION", b"go1.26.6\n"), ("go/src/make.bash", b"verified source"), ("go/LICENSE", b"license")):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                stream.addfile(info, io.BytesIO(data))
        digest = base64.b64encode(hashlib.sha256(archive.read_bytes()).digest()).decode()
        plan = {"version": 1, "candidates": [{"target": "linux-amd64"}], "sources": {"go": {
            "version": "1.26.6", "hash": "sha256-" + digest, "hashAlgorithm": "sha256", "hashMode": "flat", "stripRoot": False,
        }}}
        bootstrap = root / "bootstrap"
        bootstrap.mkdir()
        yield root, plan, archive, bootstrap


class NativeSDKTest(unittest.TestCase):
    def test_environment_clears_host_and_user_go_configuration(self):
        original = {"GOROOT": "/nix/store/wrong", "GOFLAGS": "-race", "GO_LDSO": "/bad/loader",
                    "CGO_ENABLED": "1", "CC": "missing", "GOTOOLCHAIN": "auto", "GOENV": "/user/env", "PATH": "/tools"}
        environment = sdk.build_environment(original, "linux-amd64", Path("/bootstrap"), Path("/work"))
        for key in ("GOROOT", "GOFLAGS", "GO_LDSO", "CC"):
            self.assertNotIn(key, environment)
        self.assertEqual(environment["CGO_ENABLED"], "0")
        self.assertEqual(environment["GOTOOLCHAIN"], "local")
        self.assertEqual(environment["GOENV"], "off")
        self.assertEqual(environment["GOCACHE"], "/work/cache")
        self.assertEqual(environment["PATH"], "/tools")
        self.assertEqual(original["CGO_ENABLED"], "1")

    def test_success_records_verified_source_and_only_publishes_completed_sdk(self):
        with fixture() as (root, plan, archive, bootstrap):
            calls = []

            def run(command, **kwargs):
                calls.append(command)
                self.assertTrue(Path(kwargs["env"]["GOCACHE"]).is_absolute())
                if command == ["bash", "make.bash"]:
                    built = kwargs["cwd"].parent
                    (built / "bin").mkdir()
                    (built / "bin/go").write_bytes(b"built SDK")
                    return subprocess.CompletedProcess(command, 0)
                return subprocess.CompletedProcess(command, 0, stdout="go1.26.6\n" if len(calls) == 1 else "go version go1.26.6 linux/amd64\n")

            with patch.object(sdk, "host_target", return_value="linux-amd64"), patch.object(sdk.subprocess, "run", side_effect=run):
                # Relative output paths must still give Go absolute cache paths.
                output = Path(os.path.relpath(root / "output", Path.cwd()))
                sdk.build(plan, "linux-amd64", archive, bootstrap, output)
            self.assertEqual(len(calls), 3)
            self.assertEqual((output / "bin/go").read_bytes(), b"built SDK")
            metadata = json.loads((output / "native-build.json").read_text())
            self.assertEqual(metadata["source"], plan["sources"]["go"])
            self.assertEqual(metadata["target"], "linux-amd64")
            self.assertFalse(metadata["cgo_enabled"])
            self.assertEqual(list(root.glob(".tesl-sdk-*")), [])

    def test_bad_source_is_rejected_before_any_build_command(self):
        with fixture() as (root, plan, archive, bootstrap):
            archive.write_bytes(b"corrupt")
            with patch.object(sdk, "host_target", return_value="linux-amd64"), patch.object(sdk.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "checksum"):
                    sdk.build(plan, "linux-amd64", archive, bootstrap, root / "out")
                run.assert_not_called()
            self.assertFalse((root / "out").exists())

    def test_wrong_bootstrap_or_failed_build_preserves_no_partial_output(self):
        for failure in ("bootstrap", "build"):
            with self.subTest(failure=failure), fixture() as (root, plan, archive, bootstrap):
                results = [subprocess.CompletedProcess([], 0, stdout="go1.26.6\n"), subprocess.CalledProcessError(1, ["bash"])]
                if failure == "bootstrap":
                    results = [subprocess.CompletedProcess([], 0, stdout="go1.1.0\n")]
                with patch.object(sdk, "host_target", return_value="linux-amd64"), patch.object(sdk.subprocess, "run", side_effect=results):
                    with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                        sdk.build(plan, "linux-amd64", archive, bootstrap, root / "out")
                self.assertFalse((root / "out").exists())
                self.assertEqual(list(root.glob(".tesl-sdk-*")), [])

    def test_wrong_host_target_and_existing_output_are_rejected(self):
        with fixture() as (root, plan, archive, bootstrap):
            output = root / "out"
            with patch.object(sdk, "host_target", return_value="darwin-arm64"), self.assertRaisesRegex(ValueError, "native target"):
                sdk.build(plan, "linux-amd64", archive, bootstrap, output)
            output.mkdir()
            (output / "sentinel").write_bytes(b"preserve")
            with patch.object(sdk, "host_target", return_value="linux-amd64"), self.assertRaisesRegex(ValueError, "already exists"):
                sdk.build(plan, "linux-amd64", archive, bootstrap, output)
            self.assertEqual((output / "sentinel").read_bytes(), b"preserve")


if __name__ == "__main__":
    unittest.main()

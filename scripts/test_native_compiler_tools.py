"""Provenance and failure boundaries for the temporary compiler toolchain."""

import base64
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

import native_compiler_tools as compiler


class CompilerToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tesl-compiler-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / "installed"
        self.plan = {"version": 1, "sourceDateEpoch": 123,
                     "candidates": [{"target": "linux-amd64"}, {"target": "darwin-arm64", "baseline": "macOS 13"}],
                     "sources": {}}
        self.archives = []
        for name, version, files in (
                ("ocaml", "5.4.1", {"configure": "build", "VERSION": "5.4.1\n", "LICENSE": "notice", "LICENSES/exception": "exception"}),
                ("dune", "3.21.1", {"boot/bootstrap.ml": "bootstrap"})):
            archive = self.root / (name + ".tar")
            with tarfile.open(archive, "w") as stream:
                for relative, content in files.items():
                    info = tarfile.TarInfo(name + "/" + relative)
                    info.size = len(content)
                    info.mode = 0o755 if relative == "configure" else 0o644
                    stream.addfile(info, io.BytesIO(content.encode()))
            digest = base64.b64encode(hashlib.sha256(archive.read_bytes()).digest()).decode()
            self.plan["sources"][name] = {"version": version, "hash": "sha256-" + digest,
                                         "hashAlgorithm": "sha256", "hashMode": "flat", "stripRoot": False}
            self.archives.append(archive)
        host = patch.object(compiler, "host_target", return_value="linux-amd64")
        host.start()
        self.addCleanup(host.stop)
        self.calls = []

    def fake_build(self, arguments, directory, environment, capture=False):
        args = list(map(str, arguments))
        self.calls.append(args)
        if args == ["make", "install"]:
            (self.output / "bin").mkdir()
        if "boot/bootstrap.ml" in args:
            (directory / "dune.exe").write_text("built dune")
        if capture:
            return "3.21.1" if args[-1] == "--version" else "5.4.1"

    def build(self):
        return compiler.build(self.plan, "linux-amd64", *self.archives, self.output, jobs=2)

    def test_verified_sources_and_license_tree_are_recorded(self):
        with patch.object(compiler, "run", side_effect=self.fake_build):
            result = self.build()
        self.assertEqual((result / "licenses/LICENSES/exception").read_text(), "exception")
        self.assertEqual((result / "bin/dune").read_text(), "built dune")
        evidence = json.loads((result / "native-build.json").read_text())
        self.assertEqual(evidence["sources"], self.plan["sources"])
        self.assertTrue(evidence["source_hashes_verified"])
        self.assertFalse(evidence["ocaml_compression"])
        self.assertIn("--without-zstd", self.calls[0])
        self.assertFalse(list(self.root.glob(".tesl-compiler-tools-*")))

    def test_both_archives_verify_before_any_build_script_runs(self):
        self.archives[1].write_bytes(b"tampered")
        with patch.object(compiler, "run") as run:
            with self.assertRaises(ValueError):
                self.build()
        run.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_unexpected_source_version_never_executes_configure(self):
        self.plan["sources"]["ocaml"]["version"] = "5.4.2"
        with patch.object(compiler, "run") as run:
            with self.assertRaisesRegex(ValueError, "source version"):
                self.build()
        run.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_failed_build_removes_only_its_partial_installation(self):
        preserved = self.root / "unrelated"
        preserved.write_text("keep")
        with patch.object(compiler, "run", side_effect=subprocess.CalledProcessError(1, "make")):
            with self.assertRaises(subprocess.CalledProcessError):
                self.build()
        self.assertFalse(self.output.exists())
        self.assertEqual(preserved.read_text(), "keep")
        self.assertFalse(list(self.root.glob(".tesl-compiler-tools-*")))

    def test_existing_installation_is_preserved(self):
        self.output.mkdir()
        (self.output / "keep").write_text("keep")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.build()
        self.assertEqual((self.output / "keep").read_text(), "keep")

    def test_reported_dune_version_must_match_the_pin(self):
        self.plan["sources"]["dune"]["version"] = "3.22.0"
        with patch.object(compiler, "run", side_effect=self.fake_build):
            with self.assertRaisesRegex(ValueError, "Dune version"):
                self.build()
        self.assertFalse(self.output.exists())

    def test_build_environment_excludes_host_ocaml_and_linker_injection(self):
        original = {"PATH": "system", "OCAMLPATH": "other", "OCAMLLIB": "other", "OPAM_SWITCH_PREFIX": "other",
                    "LD_PRELOAD": "injected", "CAML_LD_LIBRARY_PATH": "other", "CFLAGS": "-march=native",
                    "NIX_LDFLAGS": "other", "DUNE_PROFILE": "other", "MACOSX_DEPLOYMENT_TARGET": "99"}
        env = compiler.build_environment(original, self.plan, "darwin-arm64", self.output)
        for key in ("OCAMLPATH", "OPAM_SWITCH_PREFIX", "LD_PRELOAD", "CAML_LD_LIBRARY_PATH", "NIX_LDFLAGS", "DUNE_PROFILE"):
            self.assertNotIn(key, env)
        self.assertEqual(env["OCAMLLIB"], str(self.output / "lib/ocaml"))
        self.assertEqual(env["MACOSX_DEPLOYMENT_TARGET"], "13")
        self.assertEqual(env["CFLAGS"], "-O2")
        self.assertEqual(env["PATH"], str(self.output / "bin") + os.pathsep + "system")


if __name__ == "__main__":
    unittest.main()

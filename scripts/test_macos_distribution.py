"""Exercise final-byte signing boundaries without requiring a macOS host."""

import hashlib
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import macos_distribution as macos


class MacOSDistributionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="tesl macOS å ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.binary = self.root / "tesl"
        self.binary.write_bytes(b"original")
        self.audit = {"binaries": [{"path": "tesl", "format": "Mach-O"}]}
        self.policy = {"macOSSigning": "optional", "macOSDistribution": "ad-hoc-portable-archive"}

    def test_signs_without_credentials_and_hashes_only_verified_final_bytes(self):
        calls = []

        def run(args, **kwargs):
            self.assertTrue(kwargs["check"])
            self.assertEqual(kwargs["cwd"], self.root)
            self.assertEqual(kwargs["timeout"], 60)
            calls.append(args)
            if "--sign" in args:
                self.binary.write_bytes(b"ad-hoc signed")

        with patch.object(macos.subprocess, "run", side_effect=run):
            result = macos.sign_payload(self.root, self.audit, self.policy)
        self.assertEqual(calls, [
            ["codesign", "--force", "--sign", "-", "--timestamp=none", str(self.binary)],
            ["codesign", "--verify", "--strict", str(self.binary)]])
        self.assertEqual(result["binaries"], [{"path": "tesl", "sha256": hashlib.sha256(b"ad-hoc signed").hexdigest()}])
        self.assertFalse(result["publisher_identity"])
        self.assertFalse(result["notarized"])

    def test_signing_or_verification_failure_produces_no_success_evidence(self):
        for failure in (0, 1):
            effects = [None] * failure + [subprocess.CalledProcessError(1, "codesign")]
            with self.subTest(failure=failure), patch.object(macos.subprocess, "run", side_effect=effects):
                with self.assertRaises(subprocess.CalledProcessError):
                    macos.sign_payload(self.root, self.audit, self.policy)

    def test_missing_or_conflicting_policy_does_not_silently_downgrade(self):
        for policy in ({}, {**self.policy, "macOSSigning": "required"},
                       {**self.policy, "macOSDistribution": "signed-notarized"}):
            with self.subTest(policy=policy), patch.object(macos.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "explicit ad-hoc"):
                    macos.sign_payload(self.root, self.audit, policy)
                run.assert_not_called()

    def test_empty_duplicate_escaping_and_non_native_inventory_is_refused(self):
        original = self.audit["binaries"][0]
        for rows in ([], [original, original], [{**original, "path": "../outside"}],
                     [{**original, "path": str(self.binary)}], [{**original, "format": "ELF"}]):
            with self.subTest(rows=rows), patch.object(macos.subprocess, "run") as run:
                with self.assertRaises(ValueError):
                    macos.sign_payload(self.root, {"binaries": rows}, self.policy)
                run.assert_not_called()

    def test_inventory_cannot_redirect_to_another_file(self):
        self.binary.rename(self.root / "real")
        self.binary.symlink_to(self.root / "real")
        with patch.object(macos.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "invalid audited"):
                macos.sign_payload(self.root, self.audit, self.policy)
            run.assert_not_called()


@unittest.skipUnless(sys.platform == "darwin", "requires native Mach-O tools and codesign")
class NativeMacOSSigningTests(unittest.TestCase):
    def test_audited_library_alias_signatures_survive_relocation_and_detect_tampering(self):
        import payload_audit

        with tempfile.TemporaryDirectory(prefix="tesl signing å ") as temporary:
            work = Path(temporary).resolve()
            root = work / "original payload"
            (root / "bin").mkdir(parents=True)
            (root / "lib").mkdir()
            library = root / "lib/libanswer.1.0.dylib"
            (library.parent / "libanswer.1.dylib").symlink_to(library.name)
            (library.parent / "libanswer.dylib").symlink_to("libanswer.1.dylib")
            source = work / "answer.c"
            source.write_text('const char *answer(void) { return "tesl-native-signing-fixture"; }\n')
            main = work / "main.c"
            main.write_text('#include <stdio.h>\nconst char *answer(void);\nint main(void) { puts(answer()); return 0; }\n')
            environment = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="13.0")

            def run(args, **kwargs):
                return subprocess.run(args, check=True, capture_output=True, text=True,
                                      env=environment, timeout=60, **kwargs)

            run(["cc", "-dynamiclib", "-install_name", "@rpath/libanswer.1.dylib",
                 str(source), "-o", str(library)])
            run(["cc", str(main), "-L" + str(library.parent), "-lanswer",
                 "-Wl,-rpath,@loader_path/../lib", "-o", str(root / "bin/tool")])
            target = "darwin-arm64" if platform.machine() == "arm64" else "darwin-amd64"
            plan = {"commands": ["tesl"], "candidates": [{"target": target, "baseline": "macOS 13"}],
                    "payloads": {target: {"manifest": {"components": {
                        name: {"path": "bin/tool"} for name in payload_audit.EXECUTABLE_COMPONENTS | {"tesl"}
                    }}}}}
            inventory = payload_audit.audit(root, plan, target)
            evidence = macos.sign_payload(root, inventory, {
                "macOSSigning": "optional", "macOSDistribution": "ad-hoc-portable-archive"})
            self.assertEqual({item["path"] for item in evidence["binaries"]},
                             {"bin/tool", "lib/libanswer.1.0.dylib"})
            relocated = work / "relocated payload ü"
            root.rename(relocated)
            for item in evidence["binaries"]:
                path = relocated / item["path"]
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), item["sha256"])
                run(["codesign", "--verify", "--strict", str(path)])
            self.assertEqual(run([str(relocated / "bin/tool")]).stdout, "tesl-native-signing-fixture\n")
            library = relocated / "lib/libanswer.1.0.dylib"
            data = library.read_bytes()
            marker = b"tesl-native-signing-fixture"
            self.assertIn(marker, data)
            library.write_bytes(data.replace(marker, b"Tesl-native-signing-fixture", 1))
            with self.assertRaises(subprocess.CalledProcessError):
                run(["codesign", "--verify", "--strict", str(library)])


if __name__ == "__main__":
    unittest.main()

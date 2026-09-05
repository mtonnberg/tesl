"""Exercise final-byte signing boundaries without requiring a macOS host."""

import hashlib
from pathlib import Path
import subprocess
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


if __name__ == "__main__":
    unittest.main()

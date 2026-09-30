"""Build provenance must not bless PRs, mismatched bytes or partial matrices."""

import unittest

import native_provenance
import test_release_catalog as fixtures


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.ReleaseCatalogTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.plan, self.artifacts = self.fixture.plan, self.fixture.artifacts
        for target in native_provenance.release.TARGETS:
            folder = self.artifacts / f"native-candidate-{target}"
            (self.artifacts / target).rename(folder)
            evidence = self.artifacts / f"native-evidence-{target}"
            evidence.mkdir()
            (folder / "checks.json").rename(evidence / "checks.json")
        self.environment = {"GITHUB_REPOSITORY": "mtonnberg/tesl", "GITHUB_SHA": self.plan["sourceRevision"],
                            "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main",
                            "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2"}

    def prepare(self):
        return native_provenance.prepare(self.plan, self.artifacts, self.environment)

    def test_complete_bytes_bind_exact_plan_locks_platform_inputs_and_ci_identity(self):
        manifest = self.prepare()
        self.assertEqual(manifest["run_id"], "123")
        self.assertEqual(manifest["run_attempt"], 2)
        self.assertEqual(manifest["plan_sha256"], native_provenance.release.json_hash(self.plan))
        self.assertEqual(set(manifest["inputs"]), native_provenance.release.TARGETS)
        self.assertIn("windowsRuntimeLicense", manifest["inputs"]["windows-amd64"])
        self.assertIn("module-lock:runtime/go/go.sum", manifest["inputs"]["linux-amd64"])
        self.assertEqual(len(manifest["input_files"]), 22)
        self.assertFalse(manifest["published"])
        self.assertFalse(manifest["release_gates_verified"])
        self.assertEqual(self.prepare(), manifest)

    def test_pr_manual_fork_other_branch_and_changed_revision_cannot_attest(self):
        for key, value in (("GITHUB_EVENT_NAME", "pull_request"), ("GITHUB_EVENT_NAME", "workflow_dispatch"),
                           ("GITHUB_REPOSITORY", "someone/tesl"), ("GITHUB_REF", "refs/heads/feature"),
                           ("GITHUB_SHA", "b" * 40)):
            with self.subTest(key=key, value=value):
                environment = dict(self.environment, **{key: value})
                with self.assertRaisesRegex(ValueError, "canonical main push"):
                    native_provenance.prepare(self.plan, self.artifacts, environment)

    def test_missing_or_invalid_ci_run_identity_is_rejected(self):
        for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
            for value in ("", "0", "-1", "unknown"):
                with self.subTest(key=key, value=value), self.assertRaisesRegex(ValueError, "run and attempt"):
                    native_provenance.prepare(self.plan, self.artifacts, dict(self.environment, **{key: value}))

    def test_stable_identity_cannot_be_substituted_for_continuous_build(self):
        with self.assertRaisesRegex(ValueError, "canonical main push"):
            native_provenance.prepare(fixtures.plan_for(stable=True), self.artifacts, self.environment)

    def test_one_missing_architecture_blocks_all_provenance(self):
        (self.artifacts / "native-evidence-darwin-arm64/checks.json").unlink()
        with self.assertRaisesRegex(ValueError, "missing or redirected"):
            self.prepare()

    def test_changed_archive_and_checksum_bytes_cannot_be_signed(self):
        target = "linux-amd64"
        archive = self.artifacts / f"native-candidate-{target}" / self.plan["payloads"][target]["archiveName"]
        archive.write_bytes(b"different bytes")
        with self.assertRaisesRegex(ValueError, "artifact bytes differ"):
            self.prepare()

    def test_extra_artifact_is_rejected_instead_of_silently_attested(self):
        (self.artifacts / "unexpected.exe").write_bytes(b"unverified executable")
        with self.assertRaisesRegex(ValueError, "undeclared"):
            self.prepare()

    def test_partial_release_gates_remain_explicit_even_with_complete_native_bytes(self):
        # Provenance records origin; it does not claim minimum-OS or full CI
        # acceptance simply because the native workflow uploaded artifacts.
        path = self.artifacts / "native-candidate-darwin-arm64/distribution-checks.json"
        value = native_provenance.release.read_json(path)
        value.update(minimum_os_runtime="not-established", network_isolation="not-tested")
        path.write_bytes(native_provenance.release.canonical(value))
        manifest = self.prepare()
        self.assertFalse(manifest["release_gates_verified"])


if __name__ == "__main__":
    unittest.main()

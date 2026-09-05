"""Release failure, retry and history ordering tests using complete real files."""

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import native_payload
import release_catalog as release


def plan_for(revision="a" * 40, epoch=100, stable=False):
    base = "0.3.1"
    version = base if stable else f"{base}-dev.{epoch}.g{revision}"
    commands = ["tesl", "tesl-lsp", "tesl-dap", "tesl-mcp", "tesl-debug-inspect", "tesl-debug-attach"]
    mandatory = ["authoritative-gate", "native-parity", "offline-install", "payload-audit", "provenance"]
    source = lambda version: {"version": version, "hash": "sha256-" + "A" * 43 + "=", "hashMode": "flat"}
    plan = {"version": 1, "sourceRevision": revision, "sourceDateEpoch": epoch, "toolchainVersion": version,
            "release": {"baseVersion": base, "version": version, "channel": "stable" if stable else "continuous",
                        "publishableSource": True, "tag": "v" + version},
            "commands": commands, "sources": {name: source(number) for name, number in
                (("go", "1.26.6"), ("ocaml", "5.4.1"), ("dune", "3.21.1"), ("postgresql", "17.10"))},
            "moduleInputHashes": {"runtime/go/go.mod": "1" * 64, "runtime/go/go.sum": "2" * 64},
            "windowsBuildTools": {name: source("1.2.3") for name in ("meson", "ninja", "perl", "flex", "bison")},
            "windowsCompilerSources": {name: source("1.2.3") for name in ("flexdll", "winpthreads")},
            "windowsRuntimeLicense": source("2015-2022"),
            "releasePolicy": {"requireCompleteMatrix": True, "mandatoryChecks": mandatory, "repository": "mtonnberg/tesl",
                "gateWorkflows": {name: ".github/workflows/" + ("ci.yml" if name == "authoritative-gate" else "native-parity.yml")
                                  for name in mandatory + sorted(release.EXTRA_GATES)}, "windowsSigning": "optional"},
            "payloads": {}, "candidates": []}
    for target in sorted(release.TARGETS):
        windows = target.startswith("windows-")
        suffix = ".exe" if windows else ""
        paths = {name: "bin/" + name + suffix for name in commands}
        paths.update({name: "libexec/tesl/postgresql/bin/" + name + suffix for name in native_payload.PG_COMMANDS})
        paths.update({name: "share/tesl/" + name for name in native_payload.DIRECTORIES})
        paths.update(compiler="libexec/tesl/compiler" + suffix, go="libexec/tesl/go/bin/go" + suffix)
        components = {name: {"path": path, "version": plan["sources"]["go"]["version"] if name == "go" else
                            plan["sources"]["postgresql"]["version"] if name in native_payload.PG_COMMANDS else version}
                      for name, path in paths.items()}
        plan["payloads"][target] = {"archiveName": f"tesl-{version}-{target}" + (".zip" if windows else ".tar.gz"),
                                   "installerName": f"tesl-{version}-setup-{target}" + suffix,
                                   "manifest": {"version": 1, "target": target, "source_revision": revision,
                                                "toolchain_version": version, "components": components}}
        plan["candidates"].append({"target": target, "baseline": "Windows 11" if windows else
                                  "glibc 2.35" if target.startswith("linux-") else "macOS 13"})
    return plan


class ReleaseCatalogTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release catalog test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir()
        self.plan = plan_for()
        self.records = {"version": 1, "source": {"repository": "mtonnberg/tesl", "revision": self.plan["sourceRevision"],
                         "ref": "refs/heads/main", "event": "push", "authorized": True, "clean": True},
                        "targets": {}, "checks": {}}
        for candidate in self.plan["candidates"]:
            target = candidate["target"]
            folder = self.artifacts / target
            folder.mkdir()
            identity = {"version": 1, "target": target, "toolchain_version": self.plan["toolchainVersion"],
                        "source_revision": self.plan["sourceRevision"]}
            parity = {**identity, "native_parity": "passed", "offline_install": "not-tested"}
            name = self.plan["payloads"][target]["archiveName"]
            digest = self.asset(folder / name, (target + " actual archive bytes").encode())
            windows = target.startswith("windows-")
            distribution = {**identity, "archive": name, "sha256": digest, "candidate_only": True,
                            "published": False, "installed_workflow": "passed",
                            "checkout": {"head": self.plan["sourceRevision"], "tracked_changes": False, "worktree_preview": False},
                            "payload_audit": {"version": 1, "target": target, "baseline": candidate["baseline"],
                                              "binaries": [{"path": "bin/tesl", "format": "PE" if windows else "ELF"}]},
                            "network_isolation": {"linux": "linux-network-namespace", "darwin": "macos-pf", "windows": "windows-firewall"}[target.split("-")[0]],
                            "minimum_os_runtime": "passed", "quarantined_download": "passed",
                            "signed_distribution": "unsigned-by-policy" if windows else "signed-notarized-stapled",
                            "setup": None}
            if windows:
                setup_name = self.plan["payloads"][target]["installerName"]
                setup_digest = self.asset(folder / setup_name, b"setup with complete payload")
                distribution["setup"] = {"archive": setup_name, "sha256": setup_digest, "embedded_archive_sha256": digest,
                                         "install_launch_uninstall": "passed", "authenticode": "unsigned"}
            self.write_json(folder / "checks.json", parity)
            self.write_json(folder / "distribution-checks.json", distribution)
            self.records["targets"][target] = {"parity": target + "/checks.json", "distribution": target + "/distribution-checks.json"}

    def asset(self, path, content):
        path.write_bytes(content)
        digest = hashlib.sha256(content).hexdigest()
        path.with_name(path.name + ".sha256").write_text(f"{digest}  {path.name}\n")
        return digest

    def write_json(self, path, value):
        path.write_bytes(release.canonical(value))

    def change(self, target, kind, change):
        path = self.artifacts / self.records["targets"][target][kind]
        value = json.loads(path.read_text())
        change(value)
        self.write_json(path, value)

    def build(self):
        return release.build_catalog(self.plan, self.artifacts, self.records)

    def receipts(self):
        # First obtain actual file digests from a deliberately ineligible
        # candidate, then model independently verified CI/attestation receipts.
        self.records["checks"] = {}
        catalog = self.build()
        for gate in set(self.plan["releasePolicy"]["mandatoryChecks"]) | release.EXTRA_GATES:
            scopes = ["all"] if gate == "authoritative-gate" else sorted(release.TARGETS)
            self.records["checks"][gate] = {}
            for target in scopes:
                self.records["checks"][gate][target] = {"verification": "verified", "result": "passed",
                    "repository": self.records["source"]["repository"], "workflow": self.plan["releasePolicy"]["gateWorkflows"][gate],
                    "run_id": "1234", "run_attempt": 1, "source_revision": self.plan["sourceRevision"],
                    "toolchain_version": self.plan["toolchainVersion"], "event": self.records["source"]["event"],
                    "ref": self.records["source"]["ref"], "inputs": release.expected_inputs(self.plan, target),
                    "subjects": release.expected_subjects(gate, target, catalog["targets"], catalog["input_files"])}

    def test_complete_candidate_retains_untested_status_and_is_not_a_release(self):
        self.change("darwin-arm64", "distribution", lambda row: row.update(network_isolation="not-tested", minimum_os_runtime="not-established", signed_distribution="not-tested"))
        catalog = self.build()
        self.assertFalse(catalog["eligibility"]["publish_eligible"])
        self.assertFalse(catalog["published"])
        self.assertEqual(len(catalog["assets"]), 12)
        self.assertEqual(set(catalog["targets"]), release.TARGETS)
        self.assertEqual(catalog["targets"]["darwin-arm64"]["distribution_result"]["minimum_os_runtime"], "not-established")
        self.assertTrue(any("minimum-os-runtime/darwin-arm64" in item for item in catalog["eligibility"]["blockers"]))

    def test_verified_complete_release_accepts_explicit_unsigned_windows_policy(self):
        self.receipts()
        catalog = self.build()
        self.assertEqual(catalog["eligibility"], {"publish_eligible": True, "blockers": []})
        self.assertEqual(catalog["checks"]["signed-distribution"]["windows-amd64"]["status"], "not-required")
        self.assertNotEqual(catalog["checks"]["signed-distribution"]["windows-amd64"]["status"], "passed")
        self.assertEqual(release.canonical(catalog), release.canonical(self.build()))

    def use_ad_hoc_macos(self):
        self.plan["releasePolicy"].update(macOSSigning="optional", macOSDistribution="ad-hoc-portable-archive",
                                          macOSRecommendedInstall="nix")
        for target in ("darwin-amd64", "darwin-arm64"):
            def change(row):
                row.update(signed_distribution="ad-hoc-by-policy", quarantined_download="not-tested")
                row["payload_audit"]["macos_signatures"] = {
                    "mode": "ad-hoc", "verification": "passed", "publisher_identity": False, "notarized": False,
                    "binaries": [{"path": item["path"], "sha256": "7" * 64} for item in row["payload_audit"]["binaries"]]}
            self.change(target, "distribution", change)

    def test_explicit_ad_hoc_macos_policy_allows_release_without_signing_account(self):
        self.use_ad_hoc_macos()
        self.receipts()
        del self.records["checks"]["signed-distribution"]
        catalog = self.build()
        self.assertEqual(catalog["eligibility"], {"publish_eligible": True, "blockers": []})
        for target in ("darwin-amd64", "darwin-arm64"):
            self.assertEqual(catalog["checks"]["signed-distribution"][target]["status"], "not-required")
            self.assertEqual(catalog["targets"][target]["distribution_result"]["quarantined_download"], "not-tested")

    def test_optional_macos_signing_does_not_bypass_other_release_gates(self):
        self.use_ad_hoc_macos()
        self.change("darwin-arm64", "distribution", lambda row: row.update(network_isolation="not-tested", minimum_os_runtime="not-established"))
        self.receipts()
        del self.records["checks"]["provenance"]["darwin-arm64"]
        catalog = self.build()
        self.assertFalse(catalog["eligibility"]["publish_eligible"])
        for gate in ("offline-install", "minimum-os-runtime", "provenance"):
            self.assertEqual(catalog["checks"][gate]["darwin-arm64"]["status"], "blocked")

    def test_ad_hoc_evidence_must_cover_every_binary_without_claiming_publisher_identity(self):
        self.use_ad_hoc_macos()
        path = self.artifacts / self.records["targets"]["darwin-arm64"]["distribution"]
        original = path.read_bytes()
        for change in (lambda row: row.update(signed_distribution="signed-notarized-stapled"),
                       lambda row: row["payload_audit"]["macos_signatures"].update(verification="failed"),
                       lambda row: row["payload_audit"]["macos_signatures"].update(publisher_identity=True),
                       lambda row: row["payload_audit"]["macos_signatures"].update(notarized=True),
                       lambda row: row["payload_audit"]["macos_signatures"].update(binaries=[]),
                       lambda row: row["payload_audit"]["macos_signatures"]["binaries"][0].update(sha256="wrong")):
            path.write_bytes(original)
            self.change("darwin-arm64", "distribution", change)
            self.receipts()
            self.assertEqual(self.build()["checks"]["signed-distribution"]["darwin-arm64"]["status"], "blocked")

    def test_required_macos_signing_policy_cannot_be_satisfied_by_ad_hoc_evidence(self):
        self.use_ad_hoc_macos()
        self.plan["releasePolicy"]["macOSSigning"] = "required"
        self.receipts()
        self.assertFalse(self.build()["eligibility"]["publish_eligible"])

    def test_one_failed_architecture_cannot_produce_a_complete_catalog(self):
        for status in ("failed", "cancelled", "not-tested"):
            with self.subTest(status=status):
                self.change("linux-arm64", "parity", lambda row: row.update(native_parity=status))
                with self.assertRaisesRegex(ValueError, "architecture"):
                    self.build()

    def test_missing_target_record_and_missing_artifact_fail(self):
        record = self.records["targets"].pop("windows-amd64")
        with self.assertRaisesRegex(ValueError, "complete target"):
            self.build()
        self.records["targets"]["windows-amd64"] = record
        (self.artifacts / "linux-arm64" / self.plan["payloads"]["linux-arm64"]["archiveName"]).unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            self.build()

    def test_corrupt_bytes_cannot_be_hidden_by_a_matching_corrupt_sidecar(self):
        path = self.artifacts / "linux-amd64" / self.plan["payloads"]["linux-amd64"]["archiveName"]
        self.asset(path, b"corrupted bytes")
        with self.assertRaisesRegex(ValueError, "artifact bytes"):
            self.build()

    def test_setup_hash_and_embedded_archive_digest_are_both_checked(self):
        target = "windows-amd64"
        self.change(target, "distribution", lambda row: row["setup"].update(embedded_archive_sha256="0" * 64))
        with self.assertRaisesRegex(ValueError, "setup evidence"):
            self.build()
        self.change(target, "distribution", lambda row: row["setup"].update(embedded_archive_sha256=row["sha256"], sha256="0" * 64))
        with self.assertRaisesRegex(ValueError, "artifact bytes"):
            self.build()

    def test_sidecar_and_undeclared_extra_asset_fail(self):
        extra = self.artifacts / "unexpected.exe"
        extra.write_text("undeclared")
        with self.assertRaisesRegex(ValueError, "undeclared"):
            self.build()
        extra.unlink()
        name = self.plan["payloads"]["linux-amd64"]["archiveName"]
        (self.artifacts / "linux-amd64" / (name + ".sha256")).write_text("bad")
        with self.assertRaisesRegex(ValueError, "sidecar"):
            self.build()

    def test_traversal_and_symlink_inputs_are_rejected(self):
        original = self.records["targets"]["linux-amd64"]["parity"]
        for path in ("../outside", "/absolute", "C:alternate", "sub\\file", "a/../b", "a\nfile"):
            with self.subTest(path=path):
                self.records["targets"]["linux-amd64"]["parity"] = path
                with self.assertRaises(ValueError):
                    self.build()
        self.records["targets"]["linux-amd64"]["parity"] = original
        path = self.artifacts / original
        copy = self.root / "outside.json"
        path.rename(copy)
        path.symlink_to(copy)
        with self.assertRaisesRegex(ValueError, "redirected"):
            self.build()

    def test_stale_head_dirty_checkout_and_mixed_versions_fail(self):
        for change in (lambda row: row.update(source_revision="b" * 40),
                       lambda row: row.update(toolchain_version="0.3.0"),
                       lambda row: row["checkout"].update(head="b" * 40),
                       lambda row: row["checkout"].update(tracked_changes=True)):
            path = self.artifacts / self.records["targets"]["linux-amd64"]["distribution"]
            original = path.read_bytes()
            self.change("linux-amd64", "distribution", change)
            with self.assertRaises(ValueError):
                self.build()
            path.write_bytes(original)

    def test_missing_dependency_audit_and_wrong_baseline_fail(self):
        self.change("linux-amd64", "distribution", lambda row: row["payload_audit"].update(binaries=[]))
        with self.assertRaisesRegex(ValueError, "dependency audit"):
            self.build()
        self.change("linux-amd64", "distribution", lambda row: row["payload_audit"].update(binaries=[{}], baseline="glibc 9.99"))
        with self.assertRaisesRegex(ValueError, "dependency audit"):
            self.build()

    def test_all_declared_gates_are_required_and_unknown_receipts_rejected(self):
        self.receipts()
        self.plan["releasePolicy"]["mandatoryChecks"].append("independent-rebuild")
        self.plan["releasePolicy"]["gateWorkflows"]["independent-rebuild"] = ".github/workflows/rebuild.yml"
        self.receipts()
        del self.records["checks"]["independent-rebuild"]
        self.assertTrue(any("independent-rebuild" in item for item in self.build()["eligibility"]["blockers"]))
        self.records["checks"]["unknown"] = {}
        with self.assertRaisesRegex(ValueError, "unknown"):
            self.build()

    def test_verified_receipts_require_exact_repository_workflow_inputs_and_subjects(self):
        self.receipts()
        receipt = self.records["checks"]["provenance"]["windows-amd64"]
        for field, value in (("repository", "attacker/tesl"), ("workflow", ".github/workflows/untrusted.yml"),
                             ("source_revision", "b" * 40), ("toolchain_version", "0.3.0"),
                             ("inputs", {}), ("subjects", {}), ("event", "pull_request")):
            with self.subTest(field=field):
                previous = receipt[field]
                receipt[field] = value
                with self.assertRaisesRegex(ValueError, "receipt identity"):
                    self.build()
                receipt[field] = previous

    def test_a_success_word_without_verification_or_run_identity_is_insufficient(self):
        self.receipts()
        receipt = self.records["checks"]["authoritative-gate"]["all"]
        receipt["verification"] = "not-verified"
        self.assertFalse(self.build()["eligibility"]["publish_eligible"])
        receipt["verification"] = "verified"
        receipt["run_id"] = ""
        with self.assertRaisesRegex(ValueError, "CI run"):
            self.build()

    def test_failed_authoritative_gate_and_signing_failure_preserve_candidate_only(self):
        self.receipts()
        self.records["checks"]["authoritative-gate"]["all"]["result"] = "failed"
        self.records["checks"]["signed-distribution"]["darwin-arm64"]["result"] = "failed"
        catalog = self.build()
        self.assertFalse(catalog["eligibility"]["publish_eligible"])
        self.assertEqual(catalog["checks"]["authoritative-gate"]["all"]["reason"], "failed")

    def test_not_tested_os_network_or_signing_cannot_be_laundered_by_pass_receipts(self):
        self.change("darwin-amd64", "distribution", lambda row: row.update(network_isolation="not-tested", minimum_os_runtime="not-established", signed_distribution="not-tested"))
        self.receipts()
        catalog = self.build()
        for gate in ("offline-install", "minimum-os-runtime", "signed-distribution"):
            self.assertEqual(catalog["checks"][gate]["darwin-amd64"]["status"], "blocked")

    def test_macos_sandbox_requires_loopback_only_reachability_evidence(self):
        self.change("darwin-arm64", "distribution", lambda row: row.update(network_isolation="macos-sandbox-exec"))
        self.receipts()
        self.assertFalse(self.build()["eligibility"]["publish_eligible"])
        self.change("darwin-arm64", "distribution", lambda row: row.update(loopback_only_reachability="passed"))
        self.receipts()
        self.assertTrue(self.build()["eligibility"]["publish_eligible"])

    def test_pr_and_unapproved_source_are_ineligible_even_when_tests_pass(self):
        self.records["source"].update(event="pull_request", ref="refs/pull/100/merge")
        self.receipts()
        self.assertFalse(self.build()["eligibility"]["publish_eligible"])
        self.records["source"].update(event="push", ref="refs/heads/main", authorized=False)
        self.receipts()
        self.assertFalse(self.build()["eligibility"]["publish_eligible"])

    def test_plan_target_set_cannot_omit_or_duplicate_a_failed_platform(self):
        original = self.plan["candidates"][:]
        self.plan["candidates"] = original[:-1]
        with self.assertRaisesRegex(ValueError, "five unique"):
            self.build()
        self.plan["candidates"] = original + [original[0]]
        with self.assertRaisesRegex(ValueError, "five unique"):
            self.build()

    def test_same_catalog_retry_is_atomic_and_changed_bytes_cannot_replace_it(self):
        self.receipts()
        catalog = self.build()
        output = self.root / "catalogs" / (catalog["release_tag"] + ".json")
        self.assertTrue(release.write_immutable(output, catalog))
        first = output.read_bytes()
        self.assertFalse(release.write_immutable(output, catalog))
        changed = copy.deepcopy(catalog)
        changed["assets"][next(iter(changed["assets"]))]["sha256"] = "f" * 64
        with self.assertRaisesRegex(ValueError, "immutable"):
            release.write_immutable(output, changed)
        self.assertEqual(output.read_bytes(), first)
        self.assertFalse(list(output.parent.glob(".release-catalog-*")))

    def test_json_duplicate_keys_and_noncanonical_source_identity_fail(self):
        path = self.artifacts / "linux-amd64/checks.json"
        path.write_text('{"version":1,"version":2}')
        with self.assertRaisesRegex(ValueError, "duplicate JSON"):
            self.build()
        for mutation in (lambda plan: plan.update(sourceRevision="short"),
                         lambda plan: plan.update(toolchainVersion="0.3.1"),
                         lambda plan: plan.update(sourceDateEpoch=0),
                         lambda plan: plan["release"].update(tag="v0.3.0")):
            plan = copy.deepcopy(self.plan)
            mutation(plan)
            with self.assertRaises(ValueError):
                release.validate_plan(plan)


class ChannelTests(unittest.TestCase):
    def setUp(self):
        self.old, self.new, self.head = "a" * 40, "b" * 40, "c" * 40
        self.catalog = {"version": 1, "channel": "continuous", "source_revision": self.new,
                        "source_date_epoch": 1, "release_tag": "v0.3.1-dev.1.g" + self.new,
                        "source": {"repository": "mtonnberg/tesl"}, "eligibility": {"publish_eligible": True}}
        self.history = {"verified": True, "repository": "mtonnberg/tesl", "ref": "refs/heads/main", "head": self.head,
                        "parents": {self.head: [self.new], self.new: [self.old], self.old: []}}
        self.current = {"version": 1, "channel": "continuous", "source_revision": self.old,
                        "release_tag": "v0.3.1-dev.999.g" + self.old, "catalog_sha256": "1" * 64}

    def publication(self):
        return {"verified": True, "published": True, "repository": "mtonnberg/tesl", "release_tag": self.catalog["release_tag"],
                "source_revision": self.catalog["source_revision"], "catalog_sha256": release.json_hash(self.catalog)}

    def decision(self, current=None):
        return release.channel_decision(self.catalog, current, self.publication(), self.history, self.head)

    def test_newer_ancestry_advances_even_when_commit_timestamp_goes_backwards(self):
        result = self.decision(self.current)
        self.assertTrue(result["advance"])
        self.assertEqual(result["pointer"]["source_revision"], self.new)
        self.assertLess(self.catalog["source_date_epoch"], 999)

    def test_an_older_run_finishing_last_cannot_replace_a_newer_channel(self):
        current = self.decision(self.current)["pointer"]
        self.catalog.update(source_revision=self.old, release_tag="v0.3.1-dev.999.g" + self.old, source_date_epoch=999)
        result = self.decision(current)
        self.assertFalse(result["advance"])
        self.assertEqual(result["reason"], "older-release-finished-late")
        self.assertEqual(result["pointer"], current)

    def test_same_published_catalog_is_idempotent(self):
        pointer = self.decision()["pointer"]
        self.assertEqual(self.decision(pointer), {"advance": False, "reason": "already-current", "pointer": pointer})
        pointer["catalog_sha256"] = "2" * 64
        with self.assertRaisesRegex(ValueError, "different immutable"):
            self.decision(pointer)

    def test_candidate_and_unpublished_or_changed_bytes_cannot_advance(self):
        for field, value in (("verified", False), ("published", False), ("catalog_sha256", "0" * 64), ("source_revision", self.old)):
            receipt = self.publication()
            receipt[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "publication"):
                release.channel_decision(self.catalog, self.current, receipt, self.history, self.head)
        self.catalog["eligibility"]["publish_eligible"] = False
        with self.assertRaisesRegex(ValueError, "eligible"):
            self.decision()

    def test_stale_head_and_unverified_ancestry_are_rejected(self):
        self.history["head"] = self.new
        with self.assertRaisesRegex(ValueError, "stale"):
            self.decision()
        self.history["head"] = self.head
        self.history["verified"] = False
        with self.assertRaisesRegex(ValueError, "unverified"):
            self.decision()

    def test_unrelated_revision_and_incomplete_history_never_use_time_as_fallback(self):
        self.history["parents"][self.head] = [self.old]
        with self.assertRaisesRegex(ValueError, "not in verified main"):
            self.decision()
        self.history["parents"][self.head] = [self.new]
        self.history["parents"][self.new] = []
        with self.assertRaisesRegex(ValueError, "outside verified main"):
            self.decision(self.current)

    def test_stable_channels_need_their_own_promotion_policy(self):
        self.catalog["channel"] = "stable"
        with self.assertRaisesRegex(ValueError, "continuous"):
            self.decision()


if __name__ == "__main__":
    unittest.main()

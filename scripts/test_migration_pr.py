"""Negative static-validator regressions; never starts Go, OCaml or PostgreSQL."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

MODULE = importlib.util.spec_from_file_location("migration_pr", Path(__file__).with_name("check-migration-pr.py"))
pr = importlib.util.module_from_spec(MODULE)
MODULE.loader.exec_module(pr)


class Traceability(unittest.TestCase):
    def setUp(self):
        self.spec = json.loads(pr.read(pr.ROOT, pr.REGISTER), object_pairs_hook=pr.unique_object)

    def validate(self):
        return pr.validate(pr.ROOT, self.spec)

    def test_scoped_ready_is_not_execution_or_full_ci(self):
        report = self.validate()
        self.assertTrue(report["consistency"])
        self.assertTrue(report["release_ready"])
        self.assertGreater(report["unmapped_blocks"], 0)
        self.assertEqual(report["required_pending"], [])
        self.assertNotIn("PR-SCALE", report["required_pending"])
        self.assertTrue(report["full_ci_required"])
        self.assertFalse(report["execution_verified"])

    def test_cli_modes_and_complete_json_report(self):
        command = [sys.executable, str(pr.ROOT / "scripts/check-migration-pr.py"), "--json"]
        # The draft's historical override must not affect integrated live checks.
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", TESL_PR_REFERENCE_REF="nonexistent-historical-ref")
        for flags, status in (([], 0), (["--release-ready"], 0), (["--roadmap-reconciled"], 1)):
            with self.subTest(flags=flags):
                result = subprocess.run(command + flags, capture_output=True, text=True, env=env, timeout=10)
                self.assertEqual(result.returncode, status, result.stderr)
                report = json.loads(result.stdout)
                self.assertTrue(report["consistency"])
                self.assertTrue(report["release_ready"])
                self.assertEqual(report["reference_source"], "live-checkout")
                self.assertEqual(report["required_pending"], [])
                self.assertFalse(report["execution_verified"])
                self.assertEqual(report["unmapped_blocks"], sum(b["classification"] == "unmapped" for b in report["source_inventory"]))

    def test_pending_blocks_scoped_readiness_independently_of_roadmap(self):
        self.spec["requirements"]["PR-UNIQUE"]["status"] = "pending"
        with patch.object(pr, "blocks", return_value=[]):
            self.spec["source_mappings"] = []
            self.assertFalse(self.validate()["release_ready"])
        report = self.validate()
        self.assertEqual(set(report["required_pending"]), {"PR-UNIQUE"})
        self.assertFalse(report["release_ready"])
        self.assertFalse(report["roadmap_reconciled"])

    def test_cannot_delete_contract_and_register_requirement_together(self):
        del self.spec["requirements"]["PR-UNIQUE"]
        original = pr.read
        def changed(root, path):
            text = original(root, path)
            return "\n".join(line for line in text.splitlines() if not line.startswith("- PR-UNIQUE:")) if path == pr.CONTRACT else text
        with patch.object(pr, "read", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "requirement"):
                self.validate()

    def test_cannot_downgrade_required_scope(self):
        self.spec["requirements"]["PR-UNIQUE"]["disposition"] = "nonblocker"
        with self.assertRaisesRegex(ValueError, "reviewed scope"):
            self.validate()

    def test_pr_consistency_remains_integrated(self):
        runner = pr.read(pr.ROOT, pr.RUNNER)
        workflow = pr.read(pr.ROOT, pr.WORKFLOW)
        self.assertIn('python3 "$repo_root/scripts/check-migration-pr.py"', runner)
        self.assertIn("python3 scripts/check-migration-pr.py", workflow)
        for source in (runner, workflow):
            self.assertIn("-p 'test_migration_pr.py'", source)

    def test_missing_requirement(self):
        del self.spec["requirements"]["PR-LATENCY"]
        with self.assertRaisesRegex(ValueError, "requirement"):
            self.validate()

    def test_missing_test_declaration(self):
        self.spec["requirements"]["PR-QUEUE"]["witnesses"][0]["ref"] = "compiler/test/test_migration_queue.ml#removed_test"
        with self.assertRaisesRegex(ValueError, "missing compiler declaration"):
            self.validate()

    def test_helper_is_not_registered_compiler_test(self):
        self.spec["requirements"]["PR-QUEUE"]["witnesses"][0]["ref"] = "compiler/test/test_migration_queue.ml#replace"
        with self.assertRaisesRegex(ValueError, "unregistered compiler witness"):
            self.validate()

    def test_missing_implementation_declaration(self):
        self.spec["requirements"]["PR-DEPLOY"]["implementation"] = ["runtime/go/teslrt/migration_deploy.go#removed"]
        with self.assertRaisesRegex(ValueError, "missing Go declaration"):
            self.validate()

    def test_missing_evidence_lists(self):
        original = copy.deepcopy(self.spec)
        for field in ("implementation", "witnesses"):
            with self.subTest(field=field):
                self.spec = copy.deepcopy(original)
                self.spec["requirements"]["PR-DEPLOY"][field] = []
                with self.assertRaisesRegex(ValueError, "lacks implementation/test/mandatory runner"):
                    self.validate()

    def test_missing_runner_reference(self):
        self.spec["requirements"]["PR-QUEUE"]["witnesses"][0]["route"] = "deleted"
        with self.assertRaisesRegex(ValueError, "unknown runner reference"):
            self.validate()

    def test_runner_must_select_named_test(self):
        self.spec["requirements"]["PR-COMBINED"]["witnesses"] = [{
            "ref": "runtime/go/teslrt/migration_deploy_test.go#TestSchemaWorkerInstallIsExplicit", "route": "control"}]
        with self.assertRaisesRegex(ValueError, "missing runner reference/selection"):
            self.validate()

    def test_deleted_runner_and_workflow_edges(self):
        original_read = pr.read
        for path, old in ((pr.RUNNER, "  compiler_test test_migration_queue\n"),
                          (pr.WORKFLOW, "bash scripts/run-migration-tests.sh")):
            with self.subTest(path=path):
                def changed(root, name):
                    text = original_read(root, name)
                    return text.replace(old, "") if name == path else text
                with patch.object(pr, "read", side_effect=changed):
                    with self.assertRaisesRegex(ValueError, "runner reference"):
                        self.validate()

    def test_manual_evidence_requires_explicit_accepted_record(self):
        self.spec["requirements"]["PR-K8S"]["witnesses"][0]["evidence"] = "invented.log"
        with self.assertRaisesRegex(ValueError, "mandatory runner"):
            self.validate()

    def test_named_runtime_phase_must_select_test(self):
        self.spec["requirements"]["PR-CACHE"]["witnesses"][0]["route"] = "runtime:sse-broadcast"
        with self.assertRaisesRegex(ValueError, "runner reference/selection"):
            self.validate()

    def test_compiler_loop_must_include_suite(self):
        original = pr.read
        def changed(root, path):
            text = original(root, path)
            return text.replace("    test_staged_indexes \\\n", "") if path == pr.RUNNER else text
        with patch.object(pr, "read", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "runner reference/selection"):
                self.validate()

    def test_native_drop_requires_generated_fixture_route(self):
        self.spec["requirements"]["PR-DROP"]["witnesses"][1]["route"] = "runtime:row-retirement"
        with self.assertRaisesRegex(ValueError, "runner reference/selection"):
            self.validate()

    def test_native_harness_must_select_named_test(self):
        original = pr.read
        def changed(root, path):
            text = original(root, path)
            return text.replace("(ActualApp|CompiledQueueSource)", "(ActualApp)") if path.endswith("test_migration_table_drop_postgres.ml") else text
        with patch.object(pr, "read", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "runner reference/selection"):
                self.validate()

    def test_unique_groundwork_status_flip_is_not_evidence(self):
        req = self.spec["requirements"]["PR-UNIQUE"]
        req["status"] = "evidenced"
        req["implementation"] = ["compiler/lib/migration_inventory.ml#stage_transitions"]
        req["witnesses"] = [{"ref": "compiler/test/test_staged_indexes.ml#parse_format", "route": "compiler"}]
        with self.assertRaisesRegex(ValueError, "staged uniqueness evidence requires.*implementations"):
            self.validate()

    def test_unique_every_implementation_link_is_required(self):
        original = copy.deepcopy(self.spec)
        for ref in pr.UNIQUE_IMPLEMENTATION:
            with self.subTest(ref=ref):
                self.spec = copy.deepcopy(original)
                self.spec["requirements"]["PR-UNIQUE"]["implementation"].remove(ref)
                with self.assertRaisesRegex(ValueError, "staged uniqueness evidence requires.*implementations"):
                    self.validate()

    def test_unique_every_protocol_witness_is_required(self):
        original = copy.deepcopy(self.spec)
        for ref, route in pr.UNIQUE_WITNESSES:
            with self.subTest(ref=ref):
                self.spec = copy.deepcopy(original)
                req = self.spec["requirements"]["PR-UNIQUE"]
                req["witnesses"] = [w for w in req["witnesses"] if (w["ref"], w["route"]) != (ref, route)]
                with self.assertRaisesRegex(ValueError, "staged uniqueness evidence requires.*witnesses"):
                    self.validate()

    def test_unique_metadata_fixture_cannot_replace_runtime_witness(self):
        req = self.spec["requirements"]["PR-UNIQUE"]
        req["witnesses"] = [w for w in req["witnesses"] if not w["route"].startswith("compiler-native:")]
        req["witnesses"].append({"ref": "runtime/go/teslrt/migration_stage_text_test.go#TestStageTextDefaultResolution", "route": "runtime:stage-text-equality"})
        with self.assertRaisesRegex(ValueError, "staged uniqueness evidence requires.*witnesses"):
            self.validate()

    def test_unique_native_tests_cannot_use_fixtureless_runtime_route(self):
        req = self.spec["requirements"]["PR-UNIQUE"]
        witness = next(w for w in req["witnesses"] if "TestPgStagePreparationTextCatalogResolution" in w["ref"])
        witness["route"] = "runtime:stage-text-equality"
        with self.assertRaisesRegex(ValueError, "runner reference/selection"):
            self.validate()

    def test_unique_execution_edges_cannot_disappear(self):
        original = pr.read
        for path, calls in pr.UNIQUE_CONNECTIONS.items():
            for call in calls:
                with self.subTest(path=path, call=call):
                    self.assertIn(call, original(pr.ROOT, path))
                    def changed(root, name):
                        text = original(root, name)
                        return text.replace(call, "disconnected_link") if name == path else text
                    with patch.object(pr, "read", side_effect=changed):
                        with self.assertRaisesRegex(ValueError, "staged uniqueness execution/mutation route"):
                            self.validate()

    def test_unique_handoff_cannot_precede_retirement(self):
        original = pr.read
        path = "runtime/go/teslrt/migration_stage_execute.go"
        def changed(root, name):
            text = original(root, name)
            if name == path:
                text = text.replace("pgExecuteRowEpoch(ctx, conn", "REORDER_MARKER")
                text = text.replace("tesl_stage_handoff($1,$2)", "pgExecuteRowEpoch(ctx, conn")
                text = text.replace("REORDER_MARKER", "tesl_stage_handoff($1,$2)")
            return text
        with patch.object(pr, "read", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "retire writers before"):
                self.validate()

    def test_unique_protected_mutation_catalog_is_required(self):
        original = pr.read
        for filename, function in (
            ("migration_stage_lifecycle_spec.go", "tesl_stage_handoff"),
            ("migration_stage_lifecycle_spec.go", "tesl_finish_stage_enforcement"),
            ("migration_stage_cancel.go", "tesl_finish_stage_cancellation"),
            ("migration_stage_guard_catalog.go", "tesl_activate_stage_guards"),
        ):
            with self.subTest(function=function):
                path = "runtime/go/teslrt/" + filename
                def changed(root, name):
                    text = original(root, name)
                    return text.replace('{"' + function + '",', '{"removed_mutation",') if name == path else text
                with patch.object(pr, "read", side_effect=changed):
                    with self.assertRaisesRegex(ValueError, "protected catalog entry"):
                        self.validate()

    def test_unique_real_fixture_build_run_and_cases_are_required(self):
        original = pr.read
        for old in (
            "Compile.compile_go_file", "export ~stages ~guards ~cancelled output;",
            "go build -race -tags", "go test -p 2 -race -tags", "-run %s",
            '(compilation ~stages:true ~guards:true)', '(compilation ~stages:true ~cancelled:true)',
            'build "v4"', 'fail "guarded V3 exposed onConflict"',
            '"^TestPgStageCancel"', '"TESL_STAGE_GUARD_PROGRAMS"',
        ):
            with self.subTest(old=old):
                self.assertIn(old, original(pr.ROOT, pr.UNIQUE_HARNESS))
                def changed(root, name):
                    text = original(root, name)
                    return text.replace(old, "disconnected_fixture") if name == pr.UNIQUE_HARNESS else text
                with patch.object(pr, "read", side_effect=changed):
                    with self.assertRaisesRegex(ValueError, "staged uniqueness (harness|native fixture)"):
                        self.validate()

    def test_unique_all_named_native_declarations_are_required(self):
        original = pr.read
        for filename, names in pr.UNIQUE_NATIVE_TESTS.items():
            for test in names:
                with self.subTest(test=test):
                    path = "runtime/go/teslrt/" + filename
                    def changed(root, name):
                        text = original(root, name)
                        return text.replace("func " + test + "(", "func removedWitness(") if name == path else text
                    with patch.object(pr, "read", side_effect=changed):
                        with self.assertRaisesRegex(ValueError, "missing Go declaration"):
                            self.validate()

    def test_unique_runner_cannot_skip_native_cases_or_change_matrix(self):
        original = pr.read
        for path, old, message in (
            (pr.RUNNER, "TESL_STAGE_CANCELLATION_EXPORT", "clear export-only modes"),
            (pr.RUNNER, "export TESL_MIGRATION_TEST_REQUIRE_POSTGRES=1", "require PostgreSQL"),
            (pr.RUNNER, "test_migration_row_tables test_migration_row_indexes test_migration_additive_tail", "runner reference/selection"),
            (pr.WORKFLOW, "postgresql_$POSTGRES_MAJOR^out", "matching-major PostgreSQL matrix"),
        ):
            with self.subTest(old=old):
                self.assertIn(old, original(pr.ROOT, path))
                def changed(root, name):
                    text = original(root, name)
                    return text.replace(old, "disconnected_route") if name == path else text
                with patch.object(pr, "read", side_effect=changed):
                    with self.assertRaisesRegex(ValueError, message):
                        self.validate()

    def test_empty_queue_cannot_borrow_unrelated_evidence(self):
        self.spec["requirements"]["PR-EMPTY-QUEUE"] = copy.deepcopy(self.spec["requirements"]["PR-DROP"])
        with self.assertRaisesRegex(ValueError, "empty queue evidence requires"):
            self.validate()

    def test_empty_queue_real_source_and_native_routes_are_evidenced(self):
        report = self.validate()
        self.assertEqual(report["requirements"]["PR-EMPTY-QUEUE"]["status"], "evidenced")
        self.assertNotIn("PR-EMPTY-QUEUE", report["required_pending"])

    def test_empty_queue_old_helper_status_flip_is_not_evidence(self):
        req = self.spec["requirements"]["PR-EMPTY-QUEUE"]
        req["status"] = "evidenced"
        req["implementation"] = ["runtime/go/teslrt/migration_row_epoch.go#pgCheckRowQueueRetirement"]
        req["witnesses"] = [{"ref": "compiler/test/test_migration_queue.ml#bindings", "route": "compiler"}]
        with self.assertRaisesRegex(ValueError, "empty queue evidence requires.*execution"):
            self.validate()

    def test_empty_queue_every_execution_link_is_required(self):
        original = copy.deepcopy(self.spec)
        for ref in pr.EMPTY_QUEUE_IMPLEMENTATION:
            with self.subTest(ref=ref):
                self.spec = copy.deepcopy(original)
                self.spec["requirements"]["PR-EMPTY-QUEUE"]["implementation"].remove(ref)
                with self.assertRaisesRegex(ValueError, "empty queue evidence requires"):
                    self.validate()

    def test_empty_queue_isolated_emptiness_helper_cannot_be_promoted(self):
        req = self.spec["requirements"]["PR-EMPTY-QUEUE"]
        req["status"] = "evidenced"
        path = "runtime/go/teslrt/migration_queue_removal.go"
        req["implementation"] = [path + "#pgCheckQueueRemovalJobsEmpty"]
        req["witnesses"] = [{"ref": "compiler/test/test_migration_queue.ml#incompatible", "route": "compiler"}]
        original_read = pr.read
        def old_helper(root, name):
            if name == path:
                return "package teslrt\nfunc pgCheckQueueRemovalJobsEmpty() error { return nil }\n"
            return original_read(root, name)
        with patch.object(pr, "read", side_effect=old_helper):
            with self.assertRaisesRegex(ValueError, "empty queue evidence requires.*execution"):
                self.validate()

    def test_empty_queue_source_only_cannot_replace_native_witnesses(self):
        original = copy.deepcopy(self.spec)
        for ref in pr.EMPTY_QUEUE_WITNESSES:
            with self.subTest(ref=ref):
                self.spec = copy.deepcopy(original)
                req = self.spec["requirements"]["PR-EMPTY-QUEUE"]
                req["witnesses"] = [w for w in req["witnesses"] if w["ref"] != ref]
                with self.assertRaisesRegex(ValueError, "empty queue evidence requires.*witnesses"):
                    self.validate()

    def test_empty_queue_mutation_and_native_invocation_cannot_disappear(self):
        original_read = pr.read
        cases = (
            ("runtime/go/teslrt/migration_row_queue_removal_execute.go", "pgRowEpochDrain(", "observeOnly(", "fenced protected mutation"),
            ("runtime/go/teslrt/migration_row_queue_removal_execute.go", "tesl_remove_empty_queue(", "observe_empty_queue(", "fenced protected mutation"),
            ("runtime/go/teslrt/migration_row_queue_removal_spec.go", '{"tesl_remove_empty_queue",', '{"observe_empty_queue",', "mutation catalog entry"),
            ("runtime/go/teslrt/migration_row_control_spec.go", "pgRowQueueRemovalFunctions(namespace)", "pgObservationFunctions(namespace)", "route is disconnected"),
            ("runtime/go/teslrt/migration_row_catchup.go", "pgStageRowQueueRemoval(", "pgObserveQueueRemoval(", "route is disconnected"),
            ("runtime/go/teslrt/migration_row_catchup.go", "pgExecuteRowQueueRemoval(", "pgObserveQueueRemoval(", "route is disconnected"),
            ("runtime/go/teslrt/migration_row_command.go", "pgExecuteRowQueueRemoval(", "pgObserveQueueRemoval(", "route is disconnected"),
            (pr.EMPTY_QUEUE_HARNESS, "Compile.compile_go_source", "fake_snapshot", "compile and execute"),
            (pr.EMPTY_QUEUE_HARNESS, "go build -race", "go build", "compile and execute"),
            (pr.EMPTY_QUEUE_HARNESS, "go test -race", "go test", "compile and execute"),
            (pr.EMPTY_QUEUE_HARNESS, "-test.run %s", "-test.list %s", "compile and execute"),
            (pr.EMPTY_QUEUE_HARNESS, "compiled_history true", "compiled_history false", "compile and execute"),
            (pr.EMPTY_QUEUE_HARNESS, "fixtures/queue-removal/chain_test.go", "fixtures/queue-removal/unrelated_test.go", "native fixture is not supplied"),
            (pr.RUNNER, "unset TESL_QUEUE_REMOVAL_TEST_FILTER", ":", "clear the investigative native filter"),
        )
        for path, old, new, message in cases:
            with self.subTest(path=path, old=old):
                self.assertIn(old, original_read(pr.ROOT, path))
                def changed(root, name):
                    text = original_read(root, name)
                    return text.replace(old, new) if name == path else text
                with patch.object(pr, "read", side_effect=changed):
                    with self.assertRaisesRegex(ValueError, message):
                        self.validate()

    def test_empty_queue_missing_native_assertion_declaration_refuses(self):
        original_read = pr.read
        path = "compiler/test/fixtures/queue-removal/chain_test.go"
        def changed(root, name):
            text = original_read(root, name)
            return text.replace("func TestQueueRemovalChainProtectedBindingAndAllFences(", "func removedFenceWitness(") if name == path else text
        with patch.object(pr, "read", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "missing Go declaration"):
                self.validate()

    def test_empty_queue_removed_mandatory_route_refuses(self):
        original_read = pr.read
        def changed(root, path):
            text = original_read(root, path)
            return text.replace("test_migration_queue_application test_migration_queue_removal test_queue_candidate_app", "test_migration_queue_application test_queue_candidate_app") if path == pr.RUNNER else text
        with patch.object(pr, "read", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "runner reference/selection"):
                self.validate()

    def test_source_mapping_must_be_exact_and_resolve_requirement(self):
        original = copy.deepcopy(self.spec)
        for field, value in (("text", "deleted clause"), ("requirements", ["PR-MISSING"])):
            with self.subTest(field=field):
                self.spec = copy.deepcopy(original)
                self.spec["source_mappings"][0][field] = value
                with self.assertRaises(ValueError):
                    self.validate()

    def test_duplicate_source_mapping(self):
        self.spec["source_mappings"].append(copy.deepcopy(self.spec["source_mappings"][0]))
        with self.assertRaisesRegex(ValueError, "duplicate source mapping"):
            self.validate()

    def test_new_source_clause_is_visible_and_blocks_reconciliation(self):
        original_read = pr.read
        def changed(root, path):
            text = original_read(root, path)
            return text + "\n\nNew normative obligation.\n" if path == pr.SOURCES[0] else text
        with patch.object(pr, "read", side_effect=changed):
            report = self.validate()
        clause = next(b for b in report["source_inventory"] if b["text"] == "New normative obligation.")
        self.assertEqual(clause["classification"], "unmapped")
        self.assertFalse(report["roadmap_reconciled"])
        self.assertEqual(report["required_pending"], [])

    def test_blocks_do_not_omit_nonblank_source_lines(self):
        inventory = pr.blocks(pr.ROOT)
        for path in pr.SOURCES:
            actual = [line for line in pr.read(pr.ROOT, path).splitlines() if line.strip()]
            scanned = [line for b in inventory if b["file"] == path for line in b["text"].splitlines() if line.strip()]
            self.assertEqual([s.strip() for s in actual], [s.strip() for s in scanned])

    def test_duplicate_json_keys_and_path_escape(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            json.loads('{"a":1,"a":2}', object_pairs_hook=pr.unique_object)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "escapes"):
                pr.read(Path(directory), "../outside")


if __name__ == "__main__":
    unittest.main()

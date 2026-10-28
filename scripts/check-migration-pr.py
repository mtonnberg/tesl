#!/usr/bin/env python3
"""Static trace links, not a proof of program correctness. Python stdlib only."""
import argparse
import ast
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
REGISTER = "dev-docs/migration-pr-register.json"
CONTRACT = "dev-docs/migration-pr-scope.md"
SOURCES = (
    "roadmap/next/database-migrations.md",
    "roadmap/next/queue-payload-migrations.md",
    "roadmap/next/staged-uniqueness-guard.md",
    "dev-docs/migration-delivery-status.md",
)
DISPOSITIONS = {"required", "deferred-postmerge", "unsupported-by-design", "nonblocker"}
RUNNER = "scripts/run-migration-tests.sh"
WORKFLOW = ".github/workflows/migration-protocol.yml"
# Changing Markdown and JSON together must not silently drop a requirement or
# downgrade a blocker. Changes here require scope review too.
REVIEWED = dict.fromkeys(("KERNEL QUEUE CATCHUP DEPLOY COMBINED K8S UNIQUE LATENCY CACHE EMAIL SSE EMPTY-QUEUE DROP").split(), "required")
REVIEWED.update(SCALE="deferred-postmerge", RESERVATIONS="deferred-postmerge",
                RENAME="unsupported-by-design", SIMULTANEOUS="unsupported-by-design",
                CONVENIENCES="nonblocker")
REVIEWED = {"PR-" + key: value for key, value in REVIEWED.items()}

# These are concrete execution/mutation links, not a blanket acceptance switch.
# A standalone emptiness helper or borrowed source-only tests cannot supply them.
EMPTY_QUEUE_IMPLEMENTATION = {
    "compiler/lib/migration_declaration.ml#prepare_queue_decisions",
    "compiler/lib/migration_row_history.ml#check_internal",
    "runtime/go/teslrt/migration_row_queue_removal_execute.go#pgStageRowQueueRemoval",
    "runtime/go/teslrt/migration_row_queue_removal_execute.go#pgExecuteRowQueueRemoval",
    "runtime/go/teslrt/migration_row_queue_removal_spec.go#pgRowQueueRemovalFunctions",
}
EMPTY_QUEUE_HARNESS = "compiler/test/test_migration_queue_removal.ml"
EMPTY_QUEUE_WITNESSES = {EMPTY_QUEUE_HARNESS + "#" + name
                         for name in ("reviewed_source_scope", "native", "native_chain")}
EMPTY_QUEUE_NATIVE_TESTS = {
    "application_test.go": (
        "TestQueueRemovalNonempty", "TestQueueRemovalSurvivorsAndReplay",
        "TestQueueRemovalInFlightTransactions", "TestQueueRemovalPostWaitAdmission",
        "TestQueueRemovalCrashReplay", "TestQueueRemovalForgedStagingAndACL",
        "TestQueueRemovalFreshLatestDeployment", "TestQueueRemovalActiveAttemptRefuses",
        "TestQueueRemovalWorkerAutomation",
        "TestQueueRemovalMissingClaimAuthorityCannotManufactureEmptiness",
        "TestQueueRemovalRequiresOriginalProtocolMarker",
    ),
    "chain_test.go": (
        "TestQueueRemovalChainBlockedResumeAndHistoricalCatchup",
        "TestQueueRemovalChainAlreadyRemovedPrefix", "TestQueueRemovalChainFreshLatest",
        "TestQueueRemovalChainProtectedBindingAndAllFences",
        "TestQueueRemovalChainWitnessesPresent", "TestQueueRemovalChainOlderProducerAndClaimRace",
    ),
}

# Bounded staged uniqueness requires the whole connected lifecycle. Declaration
# syntax, an identity helper, or metadata-only tests cannot stand in for it.
UNIQUE_HARNESS = "compiler/test/test_migration_row_indexes.ml"
UNIQUE_IMPLEMENTATION = {
    "compiler/lib/migration_inventory.ml#stage_transitions",
    "compiler/lib/migration_inventory.ml#validate_stage_domains",
    "compiler/lib/migration_contract.ml#check",
    "compiler/lib/migration_program.ml#capture_history",
    "compiler/lib/migration_retained_storage_canonical.ml#version_node",
    "runtime/go/teslrt/migration_admission.go#pgAdmitMigrationTransaction",
    "runtime/go/teslrt/migration_writer_context.go#pgWriterContextFunctions",
    "runtime/go/teslrt/migration_stage_preparation.go#pgRegisterStagePreparation",
    "runtime/go/teslrt/migration_stage_guard_sql.go#pgStageGuardFunctions",
    "runtime/go/teslrt/migration_stage_guard_catalog.go#pgStageGuardCatalogFunctions",
    "runtime/go/teslrt/migration_stage_lifecycle_spec.go#pgStageLifecycleFunctions",
    "runtime/go/teslrt/migration_stage_index_authority.go#pgStageIndexAuthorities",
    "runtime/go/teslrt/migration_stage_execute.go#pgExecuteStageContract",
    "runtime/go/teslrt/migration_stage_execute.go#pgFinishStageEnforcement",
    "runtime/go/teslrt/migration_stage_cancel.go#pgStageCancellationFunctions",
    "runtime/go/teslrt/migration_stage_cancel.go#pgExecuteStageCancellations",
    "runtime/go/teslrt/migration_index_worker.go#pgRunIndexWorkerSource",
}
UNIQUE_NATIVE_TESTS = {
    "migration_stage_guard_native_test.go": ("TestPgStageGuardCompiledWindow", "TestPgStageGuardActivationBoundary"),
    "migration_stage_authority_native_test.go": ("TestPgStageGuardReviewedAuthorityBoundary",),
    "migration_stage_build_native_test.go": ("TestPgStageGuardWritesDuringUniqueBuild",),
    "migration_stage_lifecycle_native_test.go": ("TestPgStageGuardPromotionLifecycle",),
    "migration_stage_recovery_native_test.go": (
        "TestPgStageGuardContractCrashRecovery", "TestPgStageGuardFourReleaseCatchup", "TestPgStageGuardFourReleaseDeploy"),
    "migration_stage_cancellation_native_test.go": (
        "TestPgStageCancelFailedPreparationAndSuccessor", "TestPgStageCancelPublicationRecovery", "TestPgStageCancelFourReleaseCatchup"),
    "migration_stage_preparation_native_test.go": (
        "TestPgStagePreparationPredecessorCarryRestart", "TestPgStagePreparationInterruptedIndexBuild",
        "TestPgStagePreparationTextCatalogResolution", "TestPgStagePreparationTextDatabaseLocales"),
    "migration_stage_registration_boundary_test.go": ("TestPgStagePreparationWorkerRegistrationBoundary",),
}
UNIQUE_WITNESSES = {
    (UNIQUE_HARNESS + "#compilation", "compiler"),
    ("compiler/test/test_staged_indexes.ml#negative_domains", "compiler"),
    ("compiler/test/test_staged_indexes.ml#text_domains", "compiler"),
    ("compiler/test/test_staged_indexes.ml#no_conflict_promise", "compiler"),
    ("compiler/test/test_staged_indexes.ml#dependencies", "compiler"),
    ("compiler/test/test_staged_indexes.ml#memory_runtime", "compiler"),
    ("runtime/go/teslrt/migration_writer_context_test.go#TestPgWriterContextTransactionIdentity", "runtime:writer-transaction-identity"),
    ("runtime/go/teslrt/migration_stage_probe_plan_test.go#TestPgStageProbePlanAnalyzeCanReplaceForcedGenericPlan", "runtime:stage-probe-plan-boundary"),
    ("runtime/go/teslrt/migration_stage_probe_plan_test.go#TestPgStageProbePlanDisabledSeqScanStillFallsBackAfterInvalidation", "runtime:stage-probe-plan-boundary"),
} | {(f"runtime/go/teslrt/{path}#{name}", "compiler-native:test_migration_row_indexes")
     for path, names in UNIQUE_NATIVE_TESTS.items() for name in names}
UNIQUE_CONNECTIONS = {
    "runtime/go/teslrt/migration_admission.go": ('admit = "tesl_admit_writer"',),
    "runtime/go/teslrt/migration_row_control_spec.go": (
        "pgWriterContextFunctions(namespace)", "pgStageGuardFunctions(namespace)",
        "pgStageGuardCatalogFunctions(namespace)", "pgStageLifecycleFunctions(namespace)",
        "pgStageCancellationFunctions(namespace)", "tesl_activate_stage_guards(v)",
        "tesl_stage_reliance_ready(doc)", "tesl_stage_cancellations_ready(v-1)"),
    "runtime/go/teslrt/migration_row_contract_execute.go": ("return pgExecuteStageContract(",),
    "runtime/go/teslrt/migration_row_forward_execute.go": ("return pgExecuteStageCancellations(",),
    "runtime/go/teslrt/migration_row_catchup.go": ("pgExecuteStageCancellations(", "len(window.target.stageGuards) > 0"),
    "runtime/go/teslrt/migration_row_index_worker.go": ("pgFinishStageEnforcement(", "tesl_schema_stage_contracts c"),
    "runtime/go/teslrt/migration_stage_execute.go": (
        "tesl_register_stage_contract($1,$2,$3,$4,$5,$6)", "pgExecuteRowEpoch(ctx, conn",
        "tesl_stage_handoff($1,$2)", "pgRunIndexWorkerSource(ctx, ddl",
        "tesl_prepare_stage_enforcement($1)", '"drop trigger "', "tesl_finish_stage_enforcement($1)"),
    "runtime/go/teslrt/migration_stage_cancel.go": (
        "pgExecuteRowEpoch(", "pgIndexJobLockMode(", "pgIndexObserve(",
        '"drop index if exists "', '"tesl_finish_stage_cancellation"'),
    "runtime/go/teslrt/migration_stage_guard_sql.go": (
        "tesl_writer_version()", "pg_catalog.pg_advisory_xact_lock(", "force_custom_plan", "IS DISTINCT FROM"),
    "runtime/go/teslrt/migration_stage_lifecycle_spec.go": (
        "settled_doc<>", "tesl_stage_settled(v)", "i.indisvalid and i.indisready and i.indislive",
        "not i.indcheckxmin", "receipt<=0", "enforced_index_oid=target"),
}


def unique_native_harness(root):
    text = read(root, UNIQUE_HARNESS)
    required = (
        "Compile.compile_go_file", "Migration_header.create", "Migration_closure.capture",
        "export ~stages ~guards ~cancelled output;", "go build -race -tags tesl_migration_test -o app",
        "go test -p 2 -race -tags tesl_migration_test", "-run %s", "Sys.command command",
        '(compilation ~stages:false)', '(compilation ~stages:true)',
        '(compilation ~stages:true ~guards:true)', '(compilation ~stages:true ~cancelled:true)',
        'build "v1"', 'build "v2"', 'build "v3"', 'build "v3-contract"', 'build "v4"',
        'fail "guarded V3 exposed onConflict"', 'fail "unguarded V4 reliance compiled"',
        'fail "guarded/enforced obligation vanished by source omission"',
    )
    if not all(part in text for part in required):
        raise ValueError("staged uniqueness harness must compile and execute all real race-enabled releases and source refusals")
    selectors = {
        "^TestPgRowIndex": "TESL_ROW_INDEX_PROGRAMS",
        "^TestPgStagePreparation": "TESL_STAGE_PREPARATION_PROGRAMS",
        "^TestPgStageGuard": "TESL_STAGE_GUARD_PROGRAMS",
        "^TestPgStageCancel": "TESL_STAGE_CANCELLATION_PROGRAMS",
    }
    if not all(f'"{pattern}"' in text and f'"{env}"' in text for pattern, env in selectors.items()):
        raise ValueError("staged uniqueness native fixture selector/environment is disconnected")
    return selectors


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read(root, path):
    # Always inspect live checkout content, including unstaged edits. The isolated
    # draft's historical-reference override is deliberately not supported here.
    target = (root / path).resolve()
    if not target.is_relative_to(root.resolve()):
        raise ValueError(f"path escapes repository: {path}")
    return target.read_text()


def declaration(root, ref, witness=False):
    path, name = ref.split("#")
    text = read(root, path)
    if path.endswith(".py"):
        nodes = ast.parse(text).body
        for part in name.split("."):
            node = next((n for n in nodes if isinstance(n, (ast.ClassDef, ast.FunctionDef)) and n.name == part), None)
            if node is None:
                raise ValueError(f"missing Python declaration: {ref}")
            nodes = node.body
        if not isinstance(node, ast.FunctionDef):
            raise ValueError(f"not a function: {ref}")
    elif path.endswith(".go"):
        if not re.search(r"^func\s+(?:\([^\n]+\)\s+)?" + re.escape(name) + r"(?:\[|\()", text, re.M):
            raise ValueError(f"missing Go declaration: {ref}")
        if witness and (not path.endswith("_test.go") or not re.match(r"Test(?:[^a-z]|$)", name)):
            raise ValueError(f"not a Go test: {ref}")
    elif path.endswith(".ml"):
        if not re.search(r"^let\s+(?:rec\s+)?" + re.escape(name) + r"\b", text, re.M):
            raise ValueError(f"missing compiler declaration: {ref}")
        if witness and not re.search(r'test_case\s+"[^"\n]+"\s+`(?:Quick|Slow)\s+\(?' + re.escape(name) + r"\b", text):
            raise ValueError(f"unregistered compiler witness: {ref}")
    else:
        raise ValueError(f"unsupported declaration language: {ref}")
    if not witness and ("/test/" in path or path.endswith("_test.go") or path.startswith("scripts/test-")):
        raise ValueError(f"test is not production implementation: {ref}")
    return path, name


def runner_route(root, witness):
    path, name = declaration(root, witness["ref"], witness=True)
    route = witness["route"]
    runner = read(root, RUNNER)
    if route == "manual":
        return False
    if route == "kernel":
        valid = path.startswith("runtime/go/internal/migrationtest/") and bool(re.search(r'^run_phase kernel .*go .*test .*\./internal/migrationtest "\$@"$', runner, re.M))
    elif route.startswith("compiler-native:"):
        suite = route.split(":", 1)[1]
        harness = f"compiler/test/{suite}.ml"
        if harness == UNIQUE_HARNESS:
            runner_route(root, {"ref": harness + "#compilation", "route": "compiler"})
            selectors = unique_native_harness(root)
            valid = path.startswith("runtime/go/teslrt/") and any(re.search(pattern, name) for pattern in selectors)
        else:
            runner_route(root, {"ref": harness + "#native", "route": "compiler"})
            text = read(root, harness)
            command = re.search(r"TESL_ROW_TABLE_DROP_PROGRAMS=%s [^\n]+go test [^\n]+ -run '([^']+)'", text)
            valid = (path.startswith("runtime/go/teslrt/") and command
                     and re.search(command[1], name) and "fun()->export out;" in text)
    elif route == "control" or route.startswith("runtime:"):
        phase = "control" if route == "control" else route.split(":", 1)[1]
        match = re.search(r"^  runtime_test " + re.escape(phase) + r" \d+ '([^']+)'$", runner, re.M)
        valid = path.startswith("runtime/go/teslrt/") and match and re.search(match[1], name)
        valid = valid and '-tags=tesl_migration_test ./teslrt -run "$pattern"' in runner
        if ("TESL_ROW_TABLE_DROP_PROGRAMS" in read(root, path)
                or path.startswith("runtime/go/teslrt/") and Path(path).name in UNIQUE_NATIVE_TESTS):
            valid = False  # Native fixtures are supplied by the compiler harness.
    elif route == "compiler":
        suite = Path(path).stem
        valid = path.startswith("compiler/test/") and f"  compiler_test {suite}\n" in runner
        loops = re.findall(r'  for suite in \\\n([a-z0-9_\s\\]+);\s*do\n    compiler_test "\$suite"\n  done', runner)
        # Bounded literal suite lists only; shell substitutions are not accepted.
        valid = valid or (path.startswith("compiler/test/") and any(
            suite in re.findall(r'\btest_[a-z0-9_]+\b', loop) for loop in loops))
        valid = valid and 'dune exec --root "$repo_root/compiler" --no-build "./test/$1.exe"' in runner
    elif route == "python":
        valid = bool(re.search(r'^  run_phase [\w-]+ \d+ python3 "\$repo_root/' + re.escape(path) + r'"(?: |$)', runner, re.M))
        text = read(root, path)
        # A named helper alone is insufficient: require invocation or unittest discovery.
        if "." in name:
            valid = valid and name.split(".")[-1].startswith("test_") and "unittest.main()" in text
        else:
            valid = valid and len(re.findall(r"\b" + re.escape(name) + r"\(", text)) > 1
    else:
        raise ValueError(f"unknown runner reference: {route}")
    if not valid:
        raise ValueError(f"missing runner reference/selection: {witness['ref']} via {route}")
    return True


def blocks(root):
    result = []
    for path in SOURCES:
        text = read(root, path)
        for match in re.finditer(r"\S[^\n]*(?:\n(?!\s*\n)[^\n]+)*", text):
            result.append({"file": path, "line": text.count("\n", 0, match.start()) + 1,
                           "text": match.group(), "classification": "unmapped"})
    return result


def empty_queue_protocol(root, req):
    """Bounded live-link checks; runtime assertions still require real execution."""
    if not EMPTY_QUEUE_IMPLEMENTATION <= set(req["implementation"]):
        raise ValueError("empty queue evidence requires source, staging, execution and protected mutation implementations")
    linked = {w["ref"] for w in req["witnesses"] if w["route"] == "compiler"}
    if not EMPTY_QUEUE_WITNESSES <= linked:
        raise ValueError("empty queue evidence requires registered source and both compiled native witnesses")
    executor = read(root, "runtime/go/teslrt/migration_row_queue_removal_execute.go")
    catalog = read(root, "runtime/go/teslrt/migration_row_queue_removal_spec.go")
    if "pgRowEpochDrain(" not in executor or "tesl_remove_empty_queue($1,$2,$3,$4,$5)" not in executor:
        raise ValueError("empty queue execution must invoke the fenced protected mutation")
    if not re.search(r'\{"tesl_remove_empty_queue",\s*"[^"]+",\s*"boolean",\s*"volatile"', catalog):
        raise ValueError("empty queue protected mutation catalog entry is missing")
    connections = {
        "runtime/go/teslrt/migration_row_control_spec.go": ("functions = append(functions, pgRowQueueRemovalFunctions(namespace)...)",),
        "runtime/go/teslrt/migration_row_catchup.go": (
            "pgStageRowQueueRemoval(ctx, conn, window, roles, expected)",
            "pgExecuteRowQueueRemoval(step, conn, next, roles, expected)",
        ),
        "runtime/go/teslrt/migration_row_command.go": ("pgExecuteRowQueueRemoval(ctx, conn, selected, roles, expected)",),
    }
    for path, calls in connections.items():
        if not all(call in read(root, path) for call in calls):
            raise ValueError("empty queue public execution/mutation route is disconnected: " + path)
    harness = read(root, EMPTY_QUEUE_HARNESS)
    patterns = (
        r"^let native \(\) = compiled_history false$",
        r"^let native_chain \(\) = compiled_history true$",
        r"Compile\.compile_go_source\b",
        r"go build -race -tags tesl_migration_test -o app",
        r"go test -race -tags tesl_migration_test -c -o application\.test",
        r"remove root;",
        r'"\^TestQueueRemovalChain" else "\^TestQueueRemoval"',
        r"-test\.run %s",
        r"Sys\.command\(command",
    )
    if not all(re.search(pattern, harness, re.M) for pattern in patterns):
        raise ValueError("empty queue native harness must compile and execute real race-enabled fixtures")
    for filename, tests in EMPTY_QUEUE_NATIVE_TESTS.items():
        path = "compiler/test/fixtures/queue-removal/" + filename
        if path not in harness:
            raise ValueError("empty queue native fixture is not supplied by the compiler harness: " + path)
        for name in tests:
            declaration(root, path + "#" + name, witness=True)
    runner = read(root, RUNNER)
    if not re.search(r'if \[\[ "\$1" == test_migration_queue_removal \]\]; then unset TESL_QUEUE_REMOVAL_TEST_FILTER; fi', runner):
        raise ValueError("empty queue mandatory runner must clear the investigative native filter")


def unique_protocol(root, req):
    """Concrete bounded lifecycle links; execution is established by real runs."""
    if not UNIQUE_IMPLEMENTATION <= set(req["implementation"]):
        raise ValueError("staged uniqueness evidence requires source, context, guard, Contract, index, cancellation and reliance implementations")
    witnesses = {(w["ref"], w["route"]) for w in req["witnesses"]}
    if not UNIQUE_WITNESSES <= witnesses:
        raise ValueError("staged uniqueness evidence requires compiler, identity, probe and compiled lifecycle witnesses")
    unique_native_harness(root)
    for path, calls in UNIQUE_CONNECTIONS.items():
        if not all(call in read(root, path) for call in calls):
            raise ValueError("staged uniqueness execution/mutation route is disconnected: " + path)
    executor = read(root, "runtime/go/teslrt/migration_stage_execute.go")
    ordered = ("tesl_register_stage_contract($1", "pgExecuteRowEpoch(ctx, conn",
               "tesl_stage_handoff($1", "pgRunIndexWorkerSource(ctx, ddl")
    positions = [executor.index(call) for call in ordered]
    if positions != sorted(positions):
        raise ValueError("staged uniqueness must retire writers before handing off and executing target jobs")
    catalogs = {
        "migration_writer_context.go": ("tesl_admit_writer", "tesl_writer_version"),
        "migration_stage_guard_sql.go": ("tesl_stage_guard_spec", "tesl_stage_guard_body"),
        "migration_stage_guard_catalog.go": ("tesl_stage_guard_catalog", "tesl_activate_stage_guards", "tesl_stage_guards_ready"),
        "migration_stage_lifecycle_spec.go": ("tesl_register_stage_contract", "tesl_stage_handoff", "tesl_stage_target_oid",
            "tesl_prepare_stage_enforcement", "tesl_finish_stage_enforcement", "tesl_stage_reliance_ready", "tesl_stage_settled"),
        "migration_stage_cancel.go": ("tesl_stage_cancellations_ready", "tesl_finish_stage_cancellation"),
    }
    for filename, functions in catalogs.items():
        text = read(root, "runtime/go/teslrt/" + filename)
        for name in functions:
            if not re.search(r'\{"' + re.escape(name) + r'",\s*"[^"]*",\s*"[^"]+",\s*"(?:stable|volatile|immutable)"', text):
                raise ValueError("staged uniqueness protected catalog entry is missing: " + name)
    runner = read(root, RUNNER)
    if ('export TESL_MIGRATION_TEST_REQUIRE_POSTGRES=1' not in runner or
            not re.search(r'if \[\[ "\$1" == test_migration_row_indexes \]\]; then\s*'
                          r'unset TESL_ROW_INDEX_EXPORT TESL_STAGE_PREPARATION_EXPORT TESL_STAGE_GUARD_EXPORT TESL_STAGE_CANCELLATION_EXPORT\s*fi', runner)):
        raise ValueError("staged uniqueness mandatory runner must require PostgreSQL and clear export-only modes")
    workflow = read(root, WORKFLOW)
    if not all(part in workflow for part in ("'[14,18]'", "TESL_MIGRATION_TEST_POSTGRES_MAJOR", "postgresql_$POSTGRES_MAJOR^out", ".nodes.nixpkgs.locked.rev")):
        raise ValueError("staged uniqueness requires the pinned matching-major PostgreSQL matrix")


def validate(root, spec):
    if set(spec) != {"version", "requirements", "source_mappings"} or spec["version"] != 1:
        raise ValueError("unsupported register schema")
    ids = re.findall(r"^- (PR-[A-Z0-9-]+):", read(root, CONTRACT), re.M)
    requirements = spec["requirements"]
    if len(ids) != len(set(ids)) or set(ids) != set(requirements) or set(ids) != set(REVIEWED):
        raise ValueError("missing/extra/duplicate requirement relative to scoped contract")
    workflow = read(root, WORKFLOW)
    if not re.search(r"^\s+bash scripts/run-migration-tests\.sh\s*$", workflow, re.M) or "set -euo pipefail" not in read(root, RUNNER):
        raise ValueError("missing mandatory workflow runner reference")
    pending = []
    for key, req in requirements.items():
        if set(req) != {"disposition", "status", "reason", "implementation", "witnesses"}:
            raise ValueError(f"invalid fields: {key}")
        if req["disposition"] not in DISPOSITIONS or req["status"] not in {"pending", "evidenced"} or not req["reason"].strip():
            raise ValueError(f"invalid disposition/status/reason: {key}")
        if req["disposition"] != REVIEWED[key]:
            raise ValueError(f"disposition differs from reviewed scope: {key}")
        for ref in req["implementation"]:
            declaration(root, ref)
        mandatory = [runner_route(root, w) for w in req["witnesses"]]
        accepted_local = key == "PR-K8S" and req["witnesses"] == [{
            "ref": "example/kubernetes-rolling/run.py#main", "route": "manual",
            "evidence": ".tesl-stuff/rolling-final-20261019-183052/audit-summary.json",
            "acceptance": "maintainer-accepted-local"}]
        if accepted_local and "722 successful samples" not in read(root, "dev-docs/migration-delivery-status.md"):
            raise ValueError("accepted local evidence record missing")
        if req["status"] == "evidenced" and (not req["implementation"] or not mandatory or not (all(mandatory) or accepted_local)):
            raise ValueError(f"evidenced requirement lacks implementation/test/mandatory runner: {key}")
        if key == "PR-UNIQUE" and req["status"] == "evidenced":
            unique_protocol(root, req)
        if key == "PR-EMPTY-QUEUE" and req["status"] == "evidenced":
            empty_queue_protocol(root, req)
        if req["disposition"] == "required" and req["status"] != "evidenced":
            pending.append(key)
    inventory = blocks(root)
    for mapping in spec["source_mappings"]:
        if set(mapping) != {"file", "text", "classification", "requirements", "reason"}:
            raise ValueError("invalid source mapping fields")
        matches = [b for b in inventory if b["file"] == mapping["file"] and b["text"] == mapping["text"]]
        if len(matches) != 1 or matches[0]["classification"] != "unmapped":
            raise ValueError("missing/ambiguous/duplicate source mapping")
        if mapping["classification"] not in DISPOSITIONS | {"contextual", "superseded"} or not mapping["reason"].strip():
            raise ValueError("invalid source disposition")
        if not mapping["requirements"] or not set(mapping["requirements"]) <= set(requirements):
            raise ValueError("missing requirement in source mapping")
        matches[0].update({k: v for k, v in mapping.items() if k != "file"})
    unmapped = sum(b["classification"] == "unmapped" for b in inventory)
    return {"consistency": True, "release_ready": not pending,
            "roadmap_reconciled": not unmapped, "reference_source": "live-checkout",
            "full_ci_required": True, "execution_verified": False,
            "counts": {"clauses": len(requirements),
                       "required": sum(r["disposition"] == "required" for r in requirements.values()),
                       "witness_links": sum(len(r["witnesses"]) for r in requirements.values()),
                       "distinct_witnesses": len({w["ref"] for r in requirements.values() for w in r["witnesses"]}),
                       "source_blocks": len(inventory), "mapped_blocks": len(inventory) - unmapped},
            "required_pending": pending, "unmapped_blocks": unmapped, "source_inventory": inventory,
            "requirements": requirements}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-ready", action="store_true", help="Require complete scoped static links; successful full CI is still required")
    parser.add_argument("--roadmap-reconciled", action="store_true", help="Separately require classification of every background block")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        report = validate(ROOT, json.loads(read(ROOT, REGISTER), object_pairs_hook=unique_object))
    except (ValueError, OSError, KeyError, TypeError, SyntaxError) as exc:
        print(f"traceability consistency FAILED: {exc}")
        return 1
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print("Traceability consistency: PASS (static links only)")
        print("Counts: " + json.dumps(report["counts"], sort_keys=True))
        print("Required pending: " + ", ".join(report["required_pending"]))
        print(f"Unmapped source blocks: {report['unmapped_blocks']} (use --json for every file/line/text)")
        print("Scoped readiness (static): " + ("PASS" if report["release_ready"] else "INCOMPLETE"))
        print("Roadmap reconciliation: " + ("COMPLETE" if report["roadmap_reconciled"] else "INCOMPLETE"))
        print("Full CI: REQUIRED (not established by static checks)")
    return int((args.release_ready and not report["release_ready"]) or
               (args.roadmap_reconciled and not report["roadmap_reconciled"]))


if __name__ == "__main__":
    raise SystemExit(main())

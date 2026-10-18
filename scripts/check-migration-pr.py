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
        if "TESL_ROW_TABLE_DROP_PROGRAMS" in read(root, path):
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
            "evidence": ".tesl-stuff/worker-install-kube.log",
            "acceptance": "maintainer-accepted-local"}]
        if accepted_local and "731 successful samples" not in read(root, "dev-docs/migration-delivery-status.md"):
            raise ValueError("accepted local evidence record missing")
        if req["status"] == "evidenced" and (not req["implementation"] or not mandatory or not (all(mandatory) or accepted_local)):
            raise ValueError(f"evidenced requirement lacks implementation/test/mandatory runner: {key}")
        if key == "PR-UNIQUE" and req["status"] == "evidenced":
            raise ValueError(f"pending acceptance requires reviewed protocol witnesses, not groundwork: {key}")
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

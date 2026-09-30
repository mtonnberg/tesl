#!/usr/bin/env python3
"""Validate same-run native artifacts before the main-only provenance job signs.

This establishes build-input and artifact bindings, not release eligibility.
Authoritative CI and the remaining release gates must be verified by a publisher.
"""

import argparse
import os
from pathlib import Path

import release_catalog as release


def prepare(plan, artifacts, environment):
    policy = release.validate_plan(plan)
    expected = {"GITHUB_REPOSITORY": policy["repository"], "GITHUB_SHA": plan["sourceRevision"],
                "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main"}
    if (any(environment.get(key) != value for key, value in expected.items())
            or plan["release"]["channel"] != "continuous" or plan["release"].get("publishableSource") is not True):
        raise ValueError("native provenance requires the exact canonical main push")
    run_id, attempt = environment.get("GITHUB_RUN_ID", ""), environment.get("GITHUB_RUN_ATTEMPT", "")
    if not str(run_id).isdigit() or int(run_id) <= 0 or not str(attempt).isdigit() or int(attempt) <= 0:
        raise ValueError("native provenance requires a CI run and attempt identity")
    records = {"version": 1, "source": {"repository": policy["repository"], "revision": plan["sourceRevision"],
               "ref": "refs/heads/main", "event": "push", "authorized": True, "clean": True}, "checks": {},
               "targets": {target: {"parity": f"native-evidence-{target}/checks.json",
                                    "distribution": f"native-candidate-{target}/distribution-checks.json"}
                           for target in release.TARGETS}}
    # Full byte/checksum/evidence validation, including Windows setup, exact
    # clean checkout, and rejection of missing, redirected or additional files.
    # No receipt is fabricated and no missing publication gate is bypassed.
    catalog = release.build_catalog(plan, artifacts, records)
    return {"version": 1, "component": "native-build-inputs", "source_revision": plan["sourceRevision"],
            "toolchain_version": plan["toolchainVersion"], "repository": policy["repository"],
            "workflow": ".github/workflows/native-parity.yml", "run_id": str(run_id), "run_attempt": int(attempt),
            "plan_sha256": release.json_hash(plan), "input_files": catalog["input_files"],
            "inputs": {target: release.expected_inputs(plan, target) for target in sorted(release.TARGETS)},
            "published": False, "release_gates_verified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("plan", "artifacts", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    manifest = prepare(release.read_json(args.plan), args.artifacts, os.environ)
    release.write_immutable(args.output, manifest)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Validate complete release candidates without networking or publication.

Input records (version 1) contain ``source`` event metadata, ``targets`` mapping
each planned target to relative ``parity``/``distribution`` evidence paths, and
``checks`` mapping gate IDs to receipts keyed by target (or ``all`` for the
authoritative gate). Receipts carry verification/result, repository/workflow,
run_id/run_attempt, event/ref, source_revision/toolchain_version, exact ``inputs``
and ``subjects`` SHA256 maps. ``expected_inputs`` and ``expected_subjects`` define
those maps; callers can use them when normalizing externally verified evidence.

TRUST BOUNDARY: a caller must authenticate the Nix plan and verify CI identities,
check conclusions and artifact attestations BEFORE supplying receipts marked
verified. This offline module checks bindings; it does not verify signatures or
turn an arbitrary JSON assertion into authenticated CI evidence. Missing gates
produce an explicitly ineligible candidate. Malformed/mismatched bytes fail.

Channel history is likewise caller-verified commit parent data, never timestamps.
Channel decisions require a verified publication receipt and a fresh main-head
anchor; a publisher must serialize/CAS the pointer update after this decision.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

from native_payload import payload_contract
from native_source import sha256_file


TARGETS = frozenset(("linux-amd64", "linux-arm64", "darwin-amd64", "darwin-arm64", "windows-amd64"))
HEX = re.compile(r"[0-9a-f]{64}")
SHA = re.compile(r"[0-9a-f]{40}")
BASE_VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")
OFFLINE_METHODS = {"linux": {"linux-network-namespace"}, "darwin": {"macos-pf", "macos-sandbox-exec"}, "windows": {"windows-firewall"}}
EXTRA_GATES = {"minimum-os-runtime", "signed-distribution"}


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")


def json_hash(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def read_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique)


def safe_relative(value):
    if (not isinstance(value, str) or not value or not re.fullmatch(r"[A-Za-z0-9_./+-]+", value)
            or any(part in ("", ".", "..") for part in value.split("/"))):
        raise ValueError(f"unsafe release input path: {value!r}")
    return Path(value)


def validate_plan(plan):
    if plan.get("version") != 1 or not isinstance(plan.get("candidates"), list):
        raise ValueError("unsupported release plan")
    targets = [row["target"] for row in plan["candidates"]]
    if len(targets) != len(TARGETS) or set(targets) != TARGETS or set(plan.get("payloads", {})) != TARGETS:
        raise ValueError("release plan must contain all five unique native targets")
    identity = plan.get("release", {})
    base, revision, epoch = identity.get("baseVersion", ""), plan.get("sourceRevision", ""), plan.get("sourceDateEpoch")
    if not BASE_VERSION.fullmatch(base) or not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
        raise ValueError("invalid release version or source epoch")
    if SHA.fullmatch(revision):
        if epoch <= 0 or identity.get("publishableSource") is not True:
            raise ValueError("clean release source identity is inconsistent")
        expected = base if identity.get("channel") == "stable" else f"{base}-dev.{epoch}.g{revision}"
        if identity.get("channel") not in {"stable", "continuous"} or identity.get("tag") != "v" + expected:
            raise ValueError("release channel/tag differs from exact source identity")
    elif revision == "worktree":
        expected = base + "-dev.worktree"
        if identity.get("publishableSource") is not False or identity.get("tag") is not None or identity.get("channel") != "development":
            raise ValueError("worktree source must be explicitly unpublishable")
    else:
        raise ValueError("source revision must be a full commit SHA or worktree")
    if plan.get("toolchainVersion") != expected or identity.get("version") != expected:
        raise ValueError("toolchain version differs from exact source identity")
    policy = plan.get("releasePolicy", {})
    gates = policy.get("mandatoryChecks")
    if (policy.get("requireCompleteMatrix") is not True or not isinstance(gates, list) or not gates
            or len(gates) != len(set(gates)) or any(not re.fullmatch(r"[a-z][a-z0-9-]*", gate) for gate in gates)):
        raise ValueError("complete matrix and explicit unique mandatory gates are required")
    for target in TARGETS:
        payload_contract(plan, target)
    return policy


def expected_inputs(plan, target):
    """Exact source/lock/plan identities required in each verified receipt."""
    result = {"release-plan": json_hash(plan)}
    result.update({"source:" + name: pin["hash"] for name, pin in plan["sources"].items()})
    result.update({"module-lock:" + name: digest for name, digest in plan["moduleInputHashes"].items()})
    if target in ("windows-amd64", "all"):
        for section in ("windowsCompilerSources", "windowsBuildTools"):
            result.update({section + ":" + name: pin["hash"] for name, pin in plan[section].items()})
        result["windowsRuntimeLicense"] = plan["windowsRuntimeLicense"]["hash"]
    return result


def expected_subjects(gate, target, targets, inventory):
    """Receipt subjects include actual input bytes, not caller-supplied digests."""
    if target == "all":
        return {}
    row = targets[target]
    if gate == "native-parity":
        paths = [row["parity"]]
    else:
        paths = [row["distribution"], *row["assets"]]
    return {path: inventory[path]["sha256"] for path in sorted(paths)}


def check_receipt(gate, target, receipt, plan, source, subjects):
    """Return a blocker for unavailable evidence; reject identity mismatches."""
    if receipt is None:
        return "missing verified receipt"
    if not isinstance(receipt, dict):
        raise ValueError(f"invalid {gate}/{target} receipt")
    result = receipt.get("result")
    if result not in {"passed", "failed", "cancelled", "not-tested", "not-established"}:
        raise ValueError(f"invalid {gate}/{target} gate result")
    if receipt.get("verification") != "verified":
        return "receipt has not been authenticated by the caller"
    policy = plan["releasePolicy"]
    workflow = policy.get("gateWorkflows", {}).get(gate)
    repository = policy.get("repository")
    if not repository or not workflow:
        return "release plan lacks a trusted repository/workflow identity"
    expected = {"repository": repository, "workflow": workflow,
                "source_revision": plan["sourceRevision"], "toolchain_version": plan["toolchainVersion"],
                "event": source.get("event"), "ref": source.get("ref"),
                "inputs": expected_inputs(plan, target), "subjects": subjects}
    if any(receipt.get(key) != value for key, value in expected.items()):
        raise ValueError(f"{gate}/{target} receipt identity, inputs or artifact digests differ")
    if (not re.fullmatch(r"[1-9][0-9]*", str(receipt.get("run_id", "")))
            or not isinstance(receipt.get("run_attempt"), int) or isinstance(receipt["run_attempt"], bool) or receipt["run_attempt"] < 1):
        raise ValueError(f"{gate}/{target} lacks a CI run identity")
    return None if result == "passed" else result


def build_catalog(plan, artifacts_root, records):
    policy = validate_plan(plan)
    root = Path(artifacts_root)
    if root.is_symlink() or not root.is_dir() or records.get("version") != 1 or set(records.get("targets", {})) != TARGETS:
        raise ValueError("complete target records and a real artifact directory are required")
    root = root.resolve()
    inventory, targets, assets = {}, {}, {}

    def file(relative):
        path = root / safe_relative(relative)
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root):
            raise ValueError(f"missing or redirected release input: {relative}")
        information = {"sha256": sha256_file(path).hex(), "bytes": path.stat().st_size}
        inventory[relative] = information
        return path

    def asset(relative, name, digest, target, kind):
        if not isinstance(digest, str) or not HEX.fullmatch(digest) or safe_relative(name).name != name:
            raise ValueError("invalid artifact name or checksum")
        path = file(relative)
        if path.name != name or inventory[relative]["sha256"] != digest or not inventory[relative]["bytes"]:
            raise ValueError(f"artifact bytes differ from evidence: {name}")
        checksum = file(relative + ".sha256")
        if checksum.read_bytes() != f"{digest}  {name}\n".encode("ascii"):
            raise ValueError(f"checksum sidecar differs from artifact: {name}")
        if name in assets:
            raise ValueError("duplicate release asset name")
        assets[name] = {"target": target, "kind": kind, **inventory[relative]}
        assets[name + ".sha256"] = {"target": target, "kind": "checksum", **inventory[relative + ".sha256"]}
        return [relative, relative + ".sha256"]

    for target in sorted(TARGETS):
        references = records["targets"][target]
        if set(references) != {"parity", "distribution"}:
            raise ValueError("target records must identify parity and distribution evidence")
        parity_path, distribution_path = file(references["parity"]), file(references["distribution"])
        parity, distribution = read_json(parity_path), read_json(distribution_path)
        for evidence in (parity, distribution):
            if (evidence.get("version") != 1 or evidence.get("target") != target
                    or evidence.get("source_revision") != plan["sourceRevision"]
                    or evidence.get("toolchain_version") != plan["toolchainVersion"]):
                raise ValueError(f"stale or mismatched target evidence: {target}")
        if parity.get("native_parity") != "passed" or distribution.get("installed_workflow") != "passed":
            raise ValueError(f"failed or incomplete architecture: {target}")
        checkout = distribution.get("checkout", {})
        if plan["sourceRevision"] != "worktree" and (checkout.get("head") != plan["sourceRevision"]
                or checkout.get("tracked_changes") is not False or checkout.get("worktree_preview") is not False):
            raise ValueError(f"distribution did not use the exact clean checkout: {target}")
        audit = distribution.get("payload_audit", {})
        baseline = next(row["baseline"] for row in plan["candidates"] if row["target"] == target)
        if (audit.get("version") != 1 or audit.get("target") != target or audit.get("baseline") != baseline
                or not isinstance(audit.get("binaries"), list) or not audit["binaries"]):
            raise ValueError(f"missing native dependency audit: {target}")
        name = plan["payloads"][target]["archiveName"]
        if distribution.get("archive") != name:
            raise ValueError("archive evidence differs from authoritative name")
        directory = safe_relative(references["distribution"]).parent
        relative = (directory / name).as_posix()
        paths = asset(relative, name, distribution.get("sha256"), target, "archive")
        setup = distribution.get("setup")
        if target == "windows-amd64":
            if (not isinstance(setup, dict) or setup.get("archive") != plan["payloads"][target]["installerName"]
                    or setup.get("embedded_archive_sha256") != distribution["sha256"]
                    or setup.get("install_launch_uninstall") != "passed"):
                raise ValueError("Windows setup evidence is incomplete or mismatched")
            paths += asset((directory / setup["archive"]).as_posix(), setup["archive"], setup.get("sha256"), target, "setup")
        elif setup is not None:
            raise ValueError("unexpected setup asset on this target")
        targets[target] = {**references, "assets": paths, "parity_result": parity, "distribution_result": distribution}
    observed = set()
    for path in root.rglob("*"):
        relative = path.relative_to(root).as_posix()
        safe_relative(relative)
        if path.is_symlink() or not (path.is_dir() or path.is_file()):
            raise ValueError(f"unsafe extra release input: {relative}")
        if path.is_file():
            observed.add(relative)
    if observed != set(inventory):
        raise ValueError("artifact directory contains undeclared or missing files")
    source, blockers, checks = records.get("source", {}), [], {}
    channel, revision = plan["release"]["channel"], plan["sourceRevision"]
    if not isinstance(source, dict) or source.get("revision") != revision:
        raise ValueError("source authorization identifies a different revision")
    if (plan["release"].get("publishableSource") is not True or source.get("authorized") is not True
            or source.get("repository") != policy.get("repository") or source.get("clean") is not True):
        blockers.append("source: clean authorized repository revision is required")
    if channel == "continuous" and (source.get("event") != "push" or source.get("ref") != "refs/heads/main"):
        blockers.append("source: continuous publication requires a main push")
    if channel == "stable" and (source.get("event") != "push" or source.get("ref") != "refs/tags/" + plan["release"]["tag"]):
        blockers.append("source: stable publication requires the exact release tag push")
    receipts = records.get("checks", {})
    required = set(policy["mandatoryChecks"]) | EXTRA_GATES
    if not isinstance(receipts, dict) or set(receipts) - required:
        raise ValueError("unknown release gate records")
    for gate in sorted(required):
        scopes = ["all"] if gate == "authoritative-gate" else sorted(TARGETS)
        supplied = receipts.get(gate, {})
        if not isinstance(supplied, dict) or set(supplied) - set(scopes):
            raise ValueError(f"unexpected target in {gate} receipts")
        checks[gate] = {}
        for target in scopes:
            distribution = targets[target]["distribution_result"] if target != "all" else {}
            if gate == "signed-distribution" and not target.startswith("darwin-"):
                if target == "windows-amd64" and not (policy.get("windowsSigning") == "optional"
                        and distribution.get("signed_distribution") == "unsigned-by-policy"
                        and distribution["setup"].get("authenticode") == "unsigned"):
                    blockers.append(f"{gate}/{target}: Windows signing policy/evidence differs")
                checks[gate][target] = {"status": "not-required", "reason": "declared platform policy"}
                continue
            if gate == "signed-distribution" and policy.get("macOSDistribution") == "ad-hoc-portable-archive":
                audit = distribution["payload_audit"]
                signatures = audit.get("macos_signatures", {})
                binaries = signatures.get("binaries", [])
                paths = [row.get("path") for row in binaries if isinstance(row, dict)] if isinstance(binaries, list) else []
                valid = (policy.get("macOSSigning") == "optional"
                         and distribution.get("signed_distribution") == "ad-hoc-by-policy"
                         and signatures.get("mode") == "ad-hoc" and signatures.get("verification") == "passed"
                         and signatures.get("publisher_identity") is False and signatures.get("notarized") is False
                         and len(paths) == len(audit["binaries"]) and len(set(paths)) == len(paths)
                         and set(paths) == {row["path"] for row in audit["binaries"]}
                         and all(isinstance(row, dict) and isinstance(row.get("sha256"), str)
                                 and HEX.fullmatch(row["sha256"]) for row in binaries))
                reason = "Developer ID and notarization are optional; ad-hoc signatures verified" if valid else "macOS ad-hoc policy/evidence differs"
                checks[gate][target] = {"status": "not-required" if valid else "blocked", "reason": reason}
                if not valid:
                    blockers.append(f"{gate}/{target}: {reason}")
                continue
            reason = check_receipt(gate, target, supplied.get(target), plan, source,
                                   expected_subjects(gate, target, targets, inventory))
            if gate == "offline-install":
                method = distribution.get("network_isolation")
                if method not in OFFLINE_METHODS[target.split("-")[0]]:
                    reason = "outbound network isolation has not been tested"
                elif method == "macos-sandbox-exec" and distribution.get("host_local_only_reachability") != "passed":
                    reason = "macOS sandbox host-local-only reachability has not been verified"
            if gate == "minimum-os-runtime" and distribution.get("minimum_os_runtime") != "passed":
                reason = "execution on the declared minimum OS has not been established"
            if gate == "signed-distribution" and (distribution.get("signed_distribution") != "signed-notarized-stapled"
                    or distribution.get("quarantined_download") != "passed"):
                reason = "macOS signing, notarization and quarantined-download acceptance are incomplete"
            if gate == "signed-distribution" and policy.get("macOSDistribution", "signed-notarized") != "signed-notarized":
                reason = "unsupported macOS distribution policy"
            checks[gate][target] = {"status": "passed" if reason is None else "blocked", "receipt": supplied.get(target)}
            if reason is not None:
                checks[gate][target]["reason"] = reason
                blockers.append(f"{gate}/{target}: {reason}")
    return {"version": 1, "component": "release-catalog", "toolchain_version": plan["toolchainVersion"],
            "source_revision": revision, "source_date_epoch": plan["sourceDateEpoch"], "release_tag": plan["release"]["tag"],
            "channel": channel, "plan_sha256": json_hash(plan), "source": source,
            "assets": assets, "targets": targets, "input_files": inventory, "checks": checks,
            "eligibility": {"publish_eligible": not blockers, "blockers": blockers}, "published": False}


def write_immutable(path, catalog):
    """Atomically create local catalog bytes; identical retries are no-ops."""
    path, content = Path(path), canonical(catalog)
    path.parent.mkdir(parents=True, exist_ok=True)
    def existing():
        if path.is_symlink() or not path.is_file() or path.read_bytes() != content:
            raise ValueError("immutable catalog already exists with different bytes")
        return False
    if path.exists() or path.is_symlink():
        return existing()
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".release-catalog-", dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError:
            return existing()
        return True
    finally:
        if temporary is not None:
            temporary.unlink()


def channel_decision(catalog, current, publication, history, expected_main_head):
    """Plan a serialized continuous-channel update; never publish or write it."""
    if catalog.get("channel") != "continuous" or catalog.get("eligibility", {}).get("publish_eligible") is not True:
        raise ValueError("only an eligible continuous release can advance this channel")
    digest, revision = json_hash(catalog), catalog["source_revision"]
    expected = {"verified": True, "published": True, "repository": catalog["source"]["repository"],
                "release_tag": catalog["release_tag"], "source_revision": revision, "catalog_sha256": digest}
    if any(publication.get(key) != value for key, value in expected.items()):
        raise ValueError("channel requires verified publication of these exact catalog bytes")
    if (not SHA.fullmatch(expected_main_head) or history.get("verified") is not True
            or history.get("repository") != expected["repository"] or history.get("ref") != "refs/heads/main"
            or history.get("head") != expected_main_head):
        raise ValueError("stale or unverified main-history anchor")
    parents = history.get("parents", {})
    if not isinstance(parents, dict) or any(not SHA.fullmatch(commit) or not isinstance(rows, list)
            or len(rows) != len(set(rows)) or any(not SHA.fullmatch(parent) or parent == commit for parent in rows)
            for commit, rows in parents.items()):
        raise ValueError("malformed verified commit-parent graph")
    def ancestor(older, newer):
        seen, pending = set(), [newer]
        while pending:
            commit = pending.pop()
            if commit == older:
                return True
            if commit not in seen:
                seen.add(commit)
                pending.extend(parents.get(commit, []))
        return False
    if not ancestor(revision, expected_main_head):
        raise ValueError("candidate is not in verified main history")
    pointer = {"version": 1, "channel": "continuous", "source_revision": revision,
               "release_tag": catalog["release_tag"], "catalog_sha256": digest}
    if current is not None:
        if (current.get("version") != 1 or current.get("channel") != "continuous"
                or not SHA.fullmatch(current.get("source_revision", "")) or not HEX.fullmatch(current.get("catalog_sha256", ""))):
            raise ValueError("invalid current channel pointer")
        previous = current["source_revision"]
        if previous == revision:
            if current != pointer:
                raise ValueError("existing revision points at a different immutable release")
            return {"advance": False, "reason": "already-current", "pointer": current}
        if not ancestor(previous, expected_main_head):
            raise ValueError("current release is outside verified main history")
        if ancestor(revision, previous):
            return {"advance": False, "reason": "older-release-finished-late", "pointer": current}
        if not ancestor(previous, revision):
            raise ValueError("history does not establish channel advancement order")
    return {"advance": True, "reason": "newer-verified-main-revision", "pointer": pointer}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("plan", "artifacts", "records", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--require-eligible", action="store_true")
    args = parser.parse_args()
    catalog = build_catalog(read_json(args.plan), args.artifacts, read_json(args.records))
    if args.require_eligible and not catalog["eligibility"]["publish_eligible"]:
        raise SystemExit("Release remains ineligible: " + "; ".join(catalog["eligibility"]["blockers"]))
    write_immutable(args.output, catalog)
    print(json.dumps(catalog["eligibility"], sort_keys=True))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Verify main-owned teaching examples and export a self-contained evidence bundle.

Python standard library only. Compiler builds and executed examples require the
Tesl development environment. This executes trusted repository code, not a sandbox
for arbitrary submissions. The publication consumer never executes a bundle.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_VERSION = 1


class ContentError(Exception):
    pass


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def relative_file(root, name):
    if not isinstance(name, str) or not name or "\\" in name:
        raise ContentError("invalid source path")
    p = PurePosixPath(name)
    if p.is_absolute() or ".." in p.parts or str(p) != name:
        raise ContentError(f"source path must be canonical and relative: {name}")
    target = root / name
    if not target.is_file() or target.is_symlink() or not target.resolve().is_relative_to(root.resolve()):
        raise ContentError(f"source missing or outside repository: {name}")
    return target


def regions(source):
    """Named regions have unique, paired, nonnested whole-line markers."""
    result, active = {}, None
    lines = source.splitlines(keepends=True)
    for i, line in enumerate(lines):
        match = re.fullmatch(r"# content:(start|end) ([a-z][a-z0-9-]*)\n?", line)
        if not match:
            continue
        kind, name = match.groups()
        if kind == "start":
            if active or name in result:
                raise ContentError(f"nested or duplicate region: {name}")
            active = (name, i + 1)
        else:
            if not active or active[0] != name:
                raise ContentError(f"unpaired region end: {name}")
            result[name] = {"start": active[1], "end": i, "text": "".join(lines[active[1]:i])}
            active = None
    if active:
        raise ContentError(f"unclosed region: {active[0]}")
    return result


def broken_source(source, example):
    region = regions(source).get(example["broken"]["region"])
    if region is None:
        raise ContentError("broken variant refers to a missing region")
    lines = source.splitlines(keepends=True)
    replacement = example["broken"]["replacement"]
    if not isinstance(replacement, str) or not replacement.endswith("\n"):
        raise ContentError("broken replacement must end with a newline")
    return "".join(lines[:region["start"]]) + replacement + "".join(lines[region["end"]:])


def validate_catalog(catalog, root):
    if catalog.get("schema_version") != SCHEMA_VERSION:
        raise ContentError("unsupported catalog schema")
    if not isinstance(catalog.get("examples"), list) or not catalog["examples"]:
        raise ContentError("catalog must contain examples")
    seen = set()
    for name in catalog["documents"]:
        relative_file(root, name)
    for example in catalog["examples"]:
        eid = example["id"]
        if not re.fullmatch(r"[a-z][a-z0-9-]*", eid) or eid in seen:
            raise ContentError(f"invalid or duplicate example ID: {eid}")
        seen.add(eid)
        if example["coverage"] != "verified-example":
            raise ContentError("v1 executes only explicitly verified examples")
        source = relative_file(root, example["source"]).read_text()
        found = regions(source)
        if set(found) != set(example["regions"]):
            raise ContentError(f"{eid}: missing or unlisted region")
        tests = re.findall(r'^test "([^"\n]+)" \{', source, re.M)
        if not tests or tests != example["tests"] or len(set(tests)) != len(tests):
            raise ContentError(f"{eid}: expected test names/order must match nonempty source test blocks")
        expected = example["broken"]["diagnostic"]
        if not expected["message_contains"] or not expected["at_line"]:
            raise ContentError(f"{eid}: expected failure needs a message discriminator and source line")
        if broken_source(source, example) == source:
            raise ContentError(f"{eid}: broken variant is identical to repaired source")
        claim_ids = set()
        for claim in example["claims"]:
            if claim["id"] in claim_ids or not claim["text"] or not claim["evidence"]:
                raise ContentError(f"{eid}: invalid or duplicate claim")
            claim_ids.add(claim["id"])
            if not set(claim["evidence"]) <= {"broken", "repaired", "tests"}:
                raise ContentError(f"{eid}: unknown claim evidence")


def verify_context(snapshot, returncode, expected=None, source=None):
    if snapshot.get("version") != 1 or not isinstance(snapshot.get("diagnostics"), list):
        raise ContentError("compiler did not return an agent-context v1 snapshot")
    diagnostics = snapshot["diagnostics"]
    if expected is None:
        if returncode != 0 or snapshot.get("ok") is not True or diagnostics or snapshot.get("proof_obligations"):
            raise ContentError("repaired example must check without diagnostics or outstanding obligations")
    else:
        if returncode != 1 or snapshot.get("ok") is not False or len(diagnostics) != 1:
            raise ContentError("intentional failure must contain exactly its expected diagnostic")
        d = diagnostics[0]
        matching_lines = [i for i, line in enumerate(source.splitlines()) if line == expected["at_line"]]
        if (d.get("severity") != "error" or d.get("code") != expected["code"]
                or any(part not in d.get("message", "") for part in expected["message_contains"])
                or len(matching_lines) != 1 or d.get("line") != matching_lines[0]):
            raise ContentError("intentional failure is unrelated to the declared missing proof")
    return {"status": "passed", "ok": snapshot["ok"], "diagnostics": diagnostics}


def verify_go_events(output, returncode, descriptions):
    events = []
    try:
        events = [json.loads(line) for line in output.splitlines() if line.strip()]
    except json.JSONDecodeError as exc:
        raise ContentError("Go test output is not JSON events") from exc
    expected = {f"TestTesl{i}" for i in range(len(descriptions))}
    ran = {e.get("Test") for e in events if e.get("Action") == "run" and e.get("Test")}
    passed = {e.get("Test") for e in events if e.get("Action") == "pass" and e.get("Test")}
    bad = [e for e in events if e.get("Action") in ("fail", "skip") and e.get("Test")]
    started = any("TESL_GO_TESTS_STARTED" in e.get("Output", "") for e in events)
    package_fail = any(e.get("Action") == "fail" for e in events)
    if returncode or not expected or ran != expected or passed != expected or bad or not started or package_fail:
        raise ContentError("runtime evidence needs every expected test executed and passing, with no skips")
    return {"status": "passed", "tests": [
        {"name": name, "generated_name": f"TestTesl{i}"} for i, name in enumerate(descriptions)]}


def command(args, cwd, log, label, timeout=120):
    env = os.environ.copy()
    env["TESL_REPO_ROOT"] = str(ROOT)
    for name in ("TESL_TEST_NAME", "TESL_TEST_KIND", "GOFLAGS"):
        env.pop(name, None)
    start = time.monotonic()
    try:
        proc = subprocess.Popen(args, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            raise ContentError(f"{label} timed out; no evidence was accepted")
    except OSError as exc:
        raise ContentError(f"{label}: {exc}; use the Tesl development environment") from exc
    log.append({"label": label, "argv": [str(a) for a in args], "exit_code": proc.returncode,
                "elapsed_seconds": round(time.monotonic() - start, 3),
                "stdout": stdout, "stderr": stderr})
    return proc.returncode, stdout, stderr


def require_command(args, cwd, log, label, timeout=120):
    rc, out, err = command(args, cwd, log, label, timeout)
    if rc:
        raise ContentError(f"{label} failed ({rc}):\n{err[-4000:]}\n{out[-4000:]}")
    return out


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args]).decode()


def source_identity():
    names = sorted(set(git("ls-files", "-c", "-o", "--exclude-standard", "-z").split("\0")) - {""})
    files = {}
    for name in names:
        path = ROOT / name
        if path.is_symlink():
            files[name] = {"symlink": os.readlink(path)}
        elif path.is_file():
            files[name] = file_hash(path)
        else:
            files[name] = "deleted"
    return {"repository": "https://github.com/mtonnberg/tesl", "commit": git("rev-parse", "HEAD").strip(),
            "tree_sha256": digest(files), "dirty": bool(git("status", "--porcelain"))}


def export_bundle(preview):
    log = []
    require_command(["dune", "build", "bin/main.exe"], ROOT / "compiler", log, "build", 300)
    identity = source_identity()
    if identity["dirty"] and not preview:
        raise ContentError("release export requires a clean repository; use --preview for local work")
    compiler = ROOT / "compiler/_build/default/bin/main.exe"
    compiler_hash = file_hash(compiler)
    catalog = json.loads((ROOT / "content/catalog.json").read_text())
    validate_catalog(catalog, ROOT)
    payload = {"schema_version": 1, "preview": bool(preview), "source": identity,
               "compiler": {"sha256": compiler_hash, "source_tree_sha256": identity["tree_sha256"]},
               "catalog": catalog, "files": {}, "examples": {}, "reference": {}, "errors": {}}
    names = set(catalog["documents"]) | {"content/catalog.json", "content/bundle.schema.json"}
    names.update(e["source"] for e in catalog["examples"])
    for name in sorted(names):
        f = relative_file(ROOT, name)
        payload["files"][name] = {"sha256": file_hash(f), "text": f.read_text()}
    for query in catalog["reference_queries"]:
        raw = require_command([str(compiler), "--doc-json", query], ROOT, log, f"reference:{query}")
        doc = json.loads(raw)
        if doc.get("version") != 1 or not doc.get("entries"):
            raise ContentError(f"invalid builtin reference: {query}")
        payload["reference"][query] = doc
    for code in catalog["error_codes"]:
        payload["errors"][code] = require_command([str(compiler), "explain", code], ROOT, log, f"error:{code}")
    for example in catalog["examples"]:
        eid = example["id"]
        repaired = payload["files"][example["source"]]["text"]
        broken = broken_source(repaired, example)
        with tempfile.TemporaryDirectory(prefix="tesl-content-") as td:
            work = Path(td)
            entry = work / Path(example["source"]).name
            checks = {}
            for variant, text in (("broken", broken), ("repaired", repaired)):
                entry.write_text(text)
                rc, out, _ = command([str(compiler), "agent-context", str(entry)], ROOT, log, f"{eid}:{variant}")
                snapshot = json.loads(out)
                checks[variant] = verify_context(snapshot, rc,
                    example["broken"]["diagnostic"] if variant == "broken" else None, text)
            # Repair is the exact canonical region restored into the broken source.
            repaired_again = broken_source(broken, {"broken": {
                "region": example["broken"]["region"],
                "replacement": regions(repaired)[example["broken"]["region"]]["text"]}})
            if repaired_again != repaired:
                raise ContentError(f"{eid}: repair does not restore the canonical example")
            outdir = work / "go"
            require_command([str(compiler), "--backend", "go", str(entry), "--out", str(outdir)], ROOT, log, f"{eid}:emit")
            rc, out, _ = command(["go", "test", "-json", "-count=1", "-timeout=45s", "./..."],
                                 outdir, log, f"{eid}:tests", 120)
            checks["tests"] = verify_go_events(out, rc, example["tests"])
        payload["examples"][eid] = {"broken_source": broken,
            "broken_sha256": hashlib.sha256(broken.encode()).hexdigest(),
            "regions": {k: v["text"] for k, v in regions(repaired).items()}, "verification": checks}
    if source_identity() != identity or file_hash(compiler) != compiler_hash:
        raise ContentError("repository or compiler changed during verification; rerun export")
    body = {"payload": payload, "content_sha256": digest(payload), "run": {
        "created_at": datetime.now(timezone.utc).isoformat(), "commands": log}}
    return {**body, "sha256": digest(body)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("verify", "export"))
    parser.add_argument("--preview", action="store_true", help="allow and label uncommitted source")
    parser.add_argument("--out", type=Path, help="write the complete evidence bundle to this JSON file")
    args = parser.parse_args()
    if args.action == "export" and not args.out:
        parser.error("export requires --out")
    try:
        bundle = export_bundle(args.preview)
        if args.out:
            args.out.parent.mkdir(parents=True, exist_ok=True)
            args.out.write_text(json.dumps(bundle, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({"ok": True, "preview": bundle["payload"]["preview"],
            "examples": list(bundle["payload"]["examples"]), "content_sha256": bundle["content_sha256"],
            "bundle_sha256": bundle["sha256"], "output": str(args.out) if args.out else None}))
        return 0
    except (ContentError, KeyError, ValueError, OSError, subprocess.SubprocessError) as exc:
        print(f"content: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

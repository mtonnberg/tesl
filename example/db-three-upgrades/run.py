#!/usr/bin/env python3
"""Exercise three distinct non-additive upgrades with ordinary V1–V4 applications."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

EXAMPLE = Path(__file__).resolve().parent
REPO = EXAMPLE.parents[1]


def command(args, *, env=None, cwd=None, timeout=120):
    result = subprocess.run([str(a) for a in args], cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{' '.join(map(str, args))}:\n{result.stdout}\n{result.stderr}")
    return result.stdout


def apply_preview(compiler, entry, env, *args, timeout=120):
    preview = json.loads(command([compiler, "migrate", *args, entry, "--manifest-json"], env=env, timeout=timeout))
    if not preview.get("ok") or not preview.get("compilable"):
        raise RuntimeError(json.dumps(preview, indent=2))
    manifest = preview["manifest"]
    root = Path(manifest["projectRoot"])
    for item in manifest["inputs"]:
        path = Path(item["path"])
        actual = hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
        if actual != item["diskHash"]:
            raise RuntimeError(f"stale input: {path}")
    for item in manifest["directories"]:
        path = Path(item["path"])
        names = sorted(p.name for p in path.iterdir()) if path.exists() else None
        actual = None if names is None else hashlib.sha256(
            ("tesl-directory-v1\0" + "\0".join(names) + "\0").encode()).hexdigest()
        if actual != item["diskHash"]:
            raise RuntimeError(f"stale directory: {path}")
    edits = manifest["edits"]
    for edit in edits:
        path = Path(edit["path"])
        path.relative_to(root)
        actual = path.read_bytes().hex() if path.exists() else None
        if actual != edit["beforeHex"]:
            raise RuntimeError(f"stale edit: {path}")
    for edit in edits:
        path = Path(edit["path"])
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(bytes.fromhex(edit["afterHex"]))
    return preview


def build_versions(output, compiler, env):
    source = output / "source"
    (source / "schema/notes").mkdir(parents=True)
    shutil.copyfile(EXAMPLE / "tesl.toml", source / "tesl.toml")
    shutil.copyfile(EXAMPLE / "app.tesl", source / "app.tesl")
    current = source / "schema/notes/v-current.tesl"
    shutil.copyfile(EXAMPLE / "schema/notes/v-current.tesl", current)
    entry = source / "app.tesl"
    for version in (1, 2, 3, 4):
        if version > 1:
            apply_preview(compiler, entry, env, "generate", "--new-revision")
            shutil.copyfile(EXAMPLE / f"versions/v{version}.tesl", current)
            edge = source / f"migrations/notes/v{version}.tesl"
            generated = edge.read_text()
            header = generated[:generated.index("module ")]
            edge.write_text(header + (EXAMPLE / f"transitions/v{version}.tesl").read_text())
            # Refresh seals and inherited Retype columns through the compiler.
            apply_preview(compiler, entry, env, "generate")
            apply_preview(compiler, entry, env, "contract", "--version", str(version))
        for file in sorted(source.rglob("*.tesl")):
            diagnostics = json.loads(command([compiler, "agent-context", file], env=env))
            if not diagnostics["ok"]:
                raise RuntimeError(json.dumps(diagnostics, indent=2))
        release = output / f"v{version}"
        release.mkdir()
        shutil.copytree(source, release / "source")
        command([compiler, "--backend", "go", entry, "--out", release / "go"], env=env)
        command(["go", "test", "-race", "-p", "1", "./..."], cwd=release / "go", env=env, timeout=180)
        command(["go", "build", "-race", "-o", release / "app", "./cmd/app"], cwd=release / "go", env=env)
        if version in (2, 3):
            expected = f'metadata__v{version}'
            if expected not in current.read_text():
                raise RuntimeError(f"refresh did not select {expected}")
        print(f"Built ordinary application V{version}", flush=True)
    return source


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def request(number, method, path):
    req = urllib.request.Request(f"http://127.0.0.1:{number}{path}", method=method)
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.loads(response.read())


def eventually(check, *, timeout=30):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = check()
            if last:
                return
        except (OSError, urllib.error.HTTPError, ValueError):
            pass
        time.sleep(0.05)
    raise RuntimeError(f"condition did not become true; last result: {last!r}")


def exercise(output, env, catchup_from=None):
    for tool in ("initdb", "pg_ctl", "psql"):
        if not shutil.which(tool):
            raise RuntimeError(f"{tool} is required; run inside nix develop")
    processes = []
    cluster = Path(tempfile.mkdtemp(prefix="tesl-three-", dir="/tmp"))
    data = cluster / "data"
    try:
        command(["initdb", "-D", data, "-U", "demo_installer", "--auth=trust", "--no-locale", "--encoding=UTF8"])
        command(["pg_ctl", "-D", data, "-l", cluster / "postgres.log", "-o", f"-k {cluster} -h ''", "-w", "start"])
    except Exception:
        subprocess.run(["pg_ctl", "-D", str(data), "-m", "immediate", "-w", "stop"], capture_output=True)
        shutil.rmtree(cluster)
        raise
    base = dict(env, PGHOST=str(cluster), PGUSER="demo_installer", PGDATABASE="postgres")

    def sql(statement):
        return command(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atc", statement], env=base).strip()

    def stop(proc):
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)

    def app_env(login, number=0):
        return dict(env, DEMO_HOST=str(cluster), DEMO_PORT="5432", DEMO_DB="three_upgrades",
                    DEMO_OWNER="demo_owner", DEMO_WORKER="demo_worker", DEMO_REQUEST="demo_request",
                    DEMO_USER=login, DEMO_HTTP_PORT=str(number),
                    DEMO_DDL=f"host={cluster} dbname=three_upgrades user={login}")

    def schema(version, login, *args):
        return command([output / f"v{version}/app", "--schema", *args, "--json"], env=app_env(login), timeout=60)

    def serve(version, worker=False):
        number = port()
        log = open(output / f"v{version}-{'worker' if worker else 'request'}.log", "w+")
        args = [str(output / f"v{version}/app")]
        if worker:
            args += ["--schema", "worker", "--json"]
        proc = subprocess.Popen(args, env=app_env("demo_worker" if worker else "demo_request", number), stdout=log, stderr=log)
        processes.append((proc, log))
        def ready():
            if proc.poll() is not None:
                log.flush(); log.seek(0)
                raise RuntimeError(f"V{version} process exited:\n{log.read()}")
            if worker:
                log.flush(); log.seek(0)
                return "schema-worker-ready" in log.read()
            return request(number, "GET", "/health") == "ready"
        eventually(ready)
        return proc, number

    def note(number, identity="one"):
        return next(row for row in request(number, "GET", "/notes") if row["id"] == identity)

    def columns():
        return json.loads(sql("select json_agg(column_name order by ordinal_position) from information_schema.columns where table_schema='notes' and table_name='notes'"))

    try:
        sql("create role demo_owner nologin; create role demo_worker login; create role demo_request login")
        sql("create database three_upgrades")
        sql("grant create on database three_upgrades to demo_owner")
        base["PGDATABASE"] = "three_upgrades"
        sql("grant create on schema public to demo_owner")
        schema(1, "demo_installer", "install", "--worker", "demo_worker", "--request", "demo_request")
        worker, _ = serve(1, True)
        old, old_port = serve(1)
        assert request(old_port, "POST", "/seed") == "created"
        assert note(old_port)["metadata"] == {"oldText": "kept"}
        if catchup_from is not None:
            # Reach a real previously deployed version, then use only the newest
            # release for all missing conversion/Contract steps.
            for version in range(2, catchup_from + 1):
                stop(worker)
                worker, _ = serve(version, True)
                stop(old)
                schema(version, "demo_worker", "contract", f"V{version}")
                old, old_port = serve(version)
            before = sql("select row_to_json(s) from notes.tesl_schema_state s")
            if catchup_from < 3:
                refused = subprocess.run([str(output / "v4/app"), "--schema", "catch-up", "--json"],
                                         env=app_env("demo_worker"), text=True, capture_output=True, timeout=60)
                assert refused.returncode != 0 and "stop those" in refused.stderr, refused
                assert sql("select row_to_json(s) from notes.tesl_schema_state s") == before
            if catchup_from == 1:
                assert request(old_port, "PUT", "/block") == "blocked"
            stop(old)
            stop(worker)
            # Exercise the real recent-instance guard; never edit heartbeat rows.
            time.sleep(31)
            if catchup_from == 1:
                rejected = subprocess.run([str(output / "v4/app"), "--schema", "catch-up", "--json"],
                                          env=app_env("demo_worker"), text=True, capture_output=True, timeout=90)
                assert rejected.returncode != 0, rejected
                assert "reject" in rejected.stderr.lower() or "quarantin" in rejected.stderr.lower(), rejected
                assert sql("select min_version from notes.tesl_schema_state") == "1"
                old, old_port = serve(1)
                assert request(old_port, "PUT", "/repair") == "repaired"
                stop(old)
                time.sleep(31)
            caught_up = json.loads(schema(4, "demo_worker", "catch-up"))
            assert caught_up["kind"] == "schema-caught-up", caught_up
            assert caught_up["currentVersion"] == caught_up["binaryVersion"] == 4, caught_up
            assert caught_up["minVersion"] == 3, caught_up
            old, old_port = serve(4)
            row = note(old_port)
            expected_text = "repaired" if catchup_from == 1 else "kept"
            assert row["owner"] == "original-owner", row
            assert row["metadata"]["body"] == expected_text, row
            assert row["metadata"]["revision"] == 3, row
            assert "memo" not in row, row
            receipts = sql("select json_agg(v order by version,step) from notes.tesl_schema_versions v")
            assert json.loads(schema(4, "demo_worker", "catch-up")) == caught_up
            assert sql("select json_agg(v order by version,step) from notes.tesl_schema_versions v") == receipts
            print(f"PASS: latest V4 catches up from V{catchup_from}; retained data, guarded retirement and exact replay", flush=True)
            return
        for version in (2, 3, 4):
            title_change = version == 4
            prefix = "/title-" if title_change else "/"
            assert request(old_port, "PUT", prefix + "block") == "blocked"
            stop(worker)
            worker, _ = serve(version, True)
            current_proc, current_port = serve(version)
            # The current representation rejects; finality must not proceed.
            rejected = subprocess.run([str(output / f"v{version}/app"), "--schema", "contract", f"V{version}", "--json"],
                                      env=app_env("demo_worker"), text=True, capture_output=True, timeout=60)
            if rejected.returncode == 0:
                raise RuntimeError("Contract accepted a rejected row")
            diagnostic = (rejected.stdout + rejected.stderr).lower()
            if "reject" not in diagnostic and "quarantin" not in diagnostic:
                raise RuntimeError(f"Contract failed for an unexpected reason: {diagnostic}")
            if sql("select min_version from notes.tesl_schema_state") != str(version - 1):
                raise RuntimeError("failed Contract advanced the admission floor")
            if sql("select compat_floor from notes.tesl_schema_state") != str(version - 1):
                raise RuntimeError("failed Contract advanced the compatibility floor")
            # Repair through the still-admitted predecessor, exercising reverse
            # writes/invalidation rather than manually editing stored metadata.
            assert request(old_port, "PUT", prefix + "repair") == "repaired"
            def readable():
                row = note(current_port)
                if title_change:
                    return row["title"] == "repaired"
                value = row["metadata"]
                return value.get("message" if version == 2 else "body") == "repaired"
            eventually(readable)
            assert request(old_port, "PUT", prefix + "edit") == "edited"
            def edited():
                row = note(current_port)
                if title_change:
                    return row["title"] == "edited"
                value = row["metadata"]
                return value.get("message" if version == 2 else "body") == "edited"
            eventually(edited)
            assert note(current_port)["owner"] == "original-owner"
            if version == 2:
                assert note(old_port)["author"] == note(current_port)["owner"]
                assert request(old_port, "POST", "/late") == "created"
                eventually(lambda: note(current_port, "late")["owner"] == "original-owner")
            if version == 3:
                if "memo" not in columns():
                    raise RuntimeError("removed field disappeared before Contract")
                assert request(current_port, "POST", "/current") == "created"
                assert note(old_port, "current")["memo"] == "legacy-default"
                assert note(old_port)["memo"] == "retained-memo"
                assert "memo" not in note(current_port)
            if version == 4:
                before = note(current_port)
                assert request(current_port, "PUT", "/title-block") == "invalid"
                assert note(current_port) == before
            stop(old)
            schema(version, "demo_worker", "contract", f"V{version}")
            assert sql("select min_version from notes.tesl_schema_state") == str(version)
            assert sql("select compat_floor from notes.tesl_schema_state") == str(version)
            physical = columns()
            if "owner" not in physical or "author" in physical:
                raise RuntimeError(f"Contract did not finish the renamed field: {physical}")
            if version in (2, 3) and (f"metadata__v{version}" not in physical or ("metadata" if version == 2 else "metadata__v2") in physical):
                raise RuntimeError(f"wrong physical cleanup: {physical}")
            if version >= 3 and "memo" in physical:
                raise RuntimeError(f"Contract retained the removed field: {physical}")
            if version == 4 and ("metadata__v3" not in physical or "metadata__v4" in physical):
                raise RuntimeError(f"proof-only upgrade unnecessarily replaced JSONB: {physical}")
            value = note(current_port)["metadata"]
            expected = {"message": "edited", "detail": "migrated-v2"} if version == 2 else {
                "body": "edited", "origin": "writer-v2", "revision": 3}
            if value != expected:
                raise RuntimeError(f"migration lost retained metadata: {value!r}; expected {expected!r}")
            # Exact replay and surviving-version restart consume the same receipts.
            schema(version, "demo_worker", "contract", f"V{version}")
            stop(worker)
            worker, _ = serve(version, True)
            assert note(current_port)["owner"] == "original-owner"
            kind = {2: "Retype/WriteBack + Rename", 3: "Retype/WriteBack + Legacy removal", 4: "proof Revalidate"}[version]
            print(f"V{version - 1} → V{version}: {kind}; rejection, repair, overlap and Contract passed", flush=True)
            old, old_port = current_proc, current_port
        assert sql("select count(*) from notes.notes") == "3"
        assert sql("select string_agg(version::text,',' order by version) from notes.tesl_schema_versions where step='contracted' and version>1") == "2,3,4"
        print("PASS: ordinary V1 → V2 → V3 → V4 mixed non-additive rollout on one PostgreSQL database", flush=True)
    finally:
        for proc, log in reversed(processes):
            stop(proc); log.close()
        command(["pg_ctl", "-D", data, "-m", "immediate", "-w", "stop"])
        shutil.rmtree(cluster)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new output directory for source releases, binaries and logs")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--run-built", action="store_true", help="run existing releases in --output without rebuilding")
    parser.add_argument("--catch-up-only", action="store_true", help="run latest-binary V1/V2/V3 catch-up witnesses only")
    parser.add_argument("--compiler", type=Path, default=Path(os.getenv("TESL_COMPILER", REPO / "compiler/_build/default/bin/main.exe")))
    args = parser.parse_args()
    output = args.output.absolute()
    if args.build_only and args.run_built:
        parser.error("--build-only and --run-built cannot be combined")
    if output.exists() and not args.run_built:
        parser.error("output directory must not already exist")
    env = dict(os.environ, TESL_REPO_ROOT=str(REPO))
    if args.run_built:
        if not all((output / f"v{version}/app").is_file() for version in (1, 2, 3, 4)):
            parser.error("--run-built requires existing V1/V2/V3/V4 release binaries")
    else:
        output.mkdir(parents=True)
        build_versions(output, args.compiler.absolute(), env)
    if not args.build_only:
        if not args.catch_up_only:
            exercise(output, env)
        for version in (1, 2, 3):
            exercise(output, env, catchup_from=version)


if __name__ == "__main__":
    main()

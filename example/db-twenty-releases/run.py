#!/usr/bin/env python3
"""Build and deploy twenty frozen project-tracker releases on one PostgreSQL DB."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
COMMON = runpy.run_path(str(HERE.parent / "db-three-upgrades/run.py"))
SCENARIO = runpy.run_path(str(HERE / "scenario.py"))
command, preview = COMMON["command"], COMMON["apply_preview"]
TRANSFORMS, RELEASES = SCENARIO["TRANSFORMS"], SCENARIO["RELEASES"]


def build(output, compiler, env, through, resume=False, from_built=None):
    done = 0
    if resume:
        while done < through and (output / f"v{done+1}/build.json").exists():
            done += 1
        if done == through:
            return
    source = Path(tempfile.mkdtemp(prefix="source-", dir=output))
    if done:
        shutil.copytree(output / f"v{done}/source", source, dirs_exist_ok=True)
    else:
        (source / "schema/tracker").mkdir(parents=True)
        shutil.copyfile(HERE / "tesl.toml", source / "tesl.toml")
    entry, current = source / "app.tesl", source / "schema/tracker/v-current.tesl"
    checked_sources = {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest() for p in source.rglob("*.tesl")} if done else {}
    for version in range(done+1, through+1):
        started = time.monotonic()
        if from_built:
            archived = from_built / f"v{version}"
            manifest = json.loads((archived / "build.json").read_text())
            for name, expected in manifest["sources"].items():
                if hashlib.sha256((archived / "source" / name).read_bytes()).hexdigest() != expected:
                    raise RuntimeError(f"archived release source changed: V{version}/{name}")
            source = Path(tempfile.mkdtemp(prefix=f"recompile-v{version}-", dir=output))
            shutil.copytree(archived / "source", source, dirs_exist_ok=True)
            entry = source / "app.tesl"
        else:
            if version > 1:
                preview(compiler, entry, env, "generate", "--new-revision", timeout=300)
            current.write_text(SCENARIO["schema"](version))
            entry.write_text(SCENARIO["application"](version))
            if version > 1:
                edge = source / f"migrations/tracker/v{version}.tesl"
                edge.write_text(edge.read_text().split("module ", 1)[0] + SCENARIO["migration"](version))
                preview(compiler, entry, env, "generate", timeout=300)
                if version in TRANSFORMS:
                    preview(compiler, entry, env, "contract", "--version", str(version), timeout=300)
        for file in sorted(source.rglob("*.tesl")):
            key, digest = str(file.relative_to(source)), hashlib.sha256(file.read_bytes()).hexdigest()
            if checked_sources.get(key) == digest:
                continue
            context = json.loads(command([compiler, "agent-context", file], env=env, timeout=180))
            if not context["ok"]:
                raise RuntimeError(json.dumps(context, indent=2))
            checked_sources[key] = digest
        release = output / f"v{version}"
        if release.exists() and resume and not (release / "build.json").exists():
            release.rename(output / f"incomplete-v{version}-{time.time_ns()}")
        release.mkdir()
        shutil.copytree(source, release / "source")
        command([compiler, "--backend", "go", entry, "--out", release / "go"], env=env, timeout=300)
        shutil.copyfile(HERE / "postgres_api_test.go", release / "go/internal/teslmodapp/postgres_api_test.go")
        test_file = release / "go/internal/teslmodapp/module_test.go"
        tests_source = test_file.read_text()
        if tests_source.count("testExitCode := teslM.Run()") != 1:
            raise RuntimeError("generated test launcher changed; cannot bind API tests safely")
        test_file.write_text(tests_source.replace("testExitCode := teslM.Run()", "testExitCode := runBoundAPITests(teslM)", 1))
        # Pure converter fixtures run before deployment. API tests run later,
        # bound to the real retained PostgreSQL state at this version.
        tests = command(["go", "test", "-race", "-p", "1", "./..."], cwd=release / "go", env=dict(env, TESL_TEST_KIND="test"), timeout=300)
        (release / "fixtures.log").write_text(tests)
        command(["go", "build", "-race", "-o", release / "app", "./cmd/app"], cwd=release / "go", env=env, timeout=180)
        command(["go", "test", "-race", "-c", "-o", release / "api.test", "./internal/teslmodapp"], cwd=release / "go", env=env, timeout=180)
        record = {"version": version, "change": RELEASES[version], "seconds": time.monotonic()-started,
                  "compilerSha256": hashlib.sha256(compiler.read_bytes()).hexdigest(),
                  "binarySha256": hashlib.sha256((release / "app").read_bytes()).hexdigest(),
                  "apiTestSha256": hashlib.sha256((release / "api.test").read_bytes()).hexdigest(),
                  "sources": {str(p.relative_to(release / "source")): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((release / "source").rglob("*.tesl"))}}
        (release / "build.json").write_text(json.dumps(record, indent=2)+"\n")
        print(f"Built V{version}: {RELEASES[version]} ({record['seconds']:.2f}s)", flush=True)


def exercise(artifacts, env, through, evidence=None, seed_tasks=0):
    output = evidence or artifacts
    output.mkdir(parents=True, exist_ok=True)
    data = Path(tempfile.mkdtemp(prefix="postgres-data-", dir=output))
    sockets = Path(tempfile.mkdtemp(prefix="tracker20-", dir="/tmp"))
    processes, evidence = [], []
    admin = dict(env, PGHOST=str(sockets), PGPORT="5432", PGUSER="lived_installer", PGDATABASE="postgres")
    def sql(query):
        return command(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atc", query], env=admin).strip()
    def appenv(role, port=0):
        return dict(env, LIVED_HOST=str(sockets), LIVED_PORT="5432", LIVED_DB="tracker20", LIVED_USER=role,
                    LIVED_OWNER="lived_owner", LIVED_WORKER="lived_worker", LIVED_REQUEST="lived_request",
                    LIVED_DDL=f"host={sockets} dbname=tracker20 user={role}", LIVED_HTTP_PORT=str(port))
    def schema(version, role, *args, ok=True):
        result = subprocess.run([str(artifacts / f"v{version}/app"), "--schema", *args, "--json"], env=appenv(role), text=True, capture_output=True, timeout=60)
        if ok and result.returncode:
            raise RuntimeError(f"V{version} {' '.join(args)}:\n{result.stdout}\n{result.stderr}")
        return result
    def request(port, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read())
    def wait(predicate, process=None, timeout=45):
        until = time.monotonic()+timeout
        while time.monotonic() < until:
            if process and process.poll() is not None:
                raise RuntimeError(f"process exited {process.returncode}")
            try:
                if predicate():
                    return
            except (OSError, ValueError):
                pass
            time.sleep(.1)
        raise RuntimeError("bounded rollout progress deadline expired")
    def start(version, worker=False):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        log = open(output / f"v{version}-{'worker' if worker else 'request'}.log", "w+")
        args = [str(artifacts / f"v{version}/app")]
        if worker:
            args += ["--schema", "worker", "--json"]
        proc = subprocess.Popen(args, env=appenv("lived_worker" if worker else "lived_request", port), stdout=log, stderr=log)
        processes.append((proc, log))
        wait(lambda: "schema-worker-ready" in Path(log.name).read_text() if worker else request(port, "GET", "/health") == f"ready-v{version}", proc)
        return proc, port
    def stop(proc):
        if proc and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)
    def edit(port, content, title="Seed task"):
        return request(port, "PUT", "/tasks/seed-task", {"projectId": "seed-project", "title": title, "content": content})
    def verify_cohorts(port, version):
        for born in range(1, version+1):
            p = request(port, "GET", f"/projects/api-v{born}")
            m = request(port, "GET", f"/members/api-v{born}")
            t = request(port, "GET", f"/tasks/api-v{born}")
            assert p == {"id": f"api-v{born}", "name": f"Project v{born}"}, p
            assert m == {"id": f"api-v{born}", "name": f"Member v{born}"}, m
            assert t["projectId"] == f"api-v{born}" and t["title"] == f"Updated v{born}" and t["content"] == f"updated-v{born}", t
            assert t["flavor"] == ("legacy" if version < 7 else "migrated-v7" if born < 7 else "created"), t
            assert t["revision"] == (0 if version < 13 else 13), t
            if born >= 6:
                assert request(port, "GET", f"/audits/api-v{born}") == {"id": f"api-v{born}", "name": f"Audit v{born}"}
    def optional_values(born, version):
        values = {"projects": {}, "tasks": {}, "members": {}, "audits": {}}
        for introduced, table, field, value in [
            (2, "tasks", "priority", born*10),
            (3, "projects", "color", f"color-{born}"),
            (3, "projects", "timezone" if version < 17 else "zone", f"zone-{born}"),
            (4, "members", "role", f"role-{born}"),
            (8, "members", "active", born % 2 == 0),
            (10, "tasks", "due", f"due-{born}"),
            (12, "projects", "archived", born % 2 == 0),
            (14, "audits", "category", f"category-{born}"),
            (16, "members", "contact", f"contact-{born}"),
            (19, "projects", "external_code", f"external-{born}"),
            (19, "members", "note", f"note-{born}"),
        ]:
            if introduced <= version and not (field == "role" and version >= 20):
                values[table][field] = value if born >= introduced else None
        return values
    def enrich_and_verify(version):
        # Valid non-default fixture values expose lossy optional-field copying.
        # Only this independent observer seeding uses SQL, after Contract/closure;
        # all business cohorts and edits are made through the application's API.
        for table, values in optional_values(version, version).items():
            if not values:
                continue
            assignments = []
            for field, value in values.items():
                encoded = ("true" if value else "false") if isinstance(value, bool) else str(value) if isinstance(value, int) else "'" + value.replace("'", "''") + "'"
                assignments.append('"' + field + '"=' + encoded)
            sql(f"update tracker.{table} set {','.join(assignments)} where id='api-v{version}'")
        for born in range(1, version+1):
            for table, values in optional_values(born, version).items():
                if not values or table == "audits" and born < 6:
                    continue
                row = json.loads(sql(f"select row_to_json(t) from tracker.{table} t where id='api-v{born}'"))
                for field, value in values.items():
                    assert row[field] == value, (version, born, table, field, row[field], value)
    try:
        command(["initdb", "-D", data, "-U", "lived_installer", "--auth=trust", "--no-locale", "--encoding=UTF8"])
        command(["pg_ctl", "-D", data, "-l", output / "postgres.log", "-o", f"-k {sockets} -h '' -c max_connections=40", "-w", "start"])
        sql("create role lived_owner nologin; create role lived_worker login; create role lived_request login")
        sql("create database tracker20")
        sql("grant create on database tracker20 to lived_owner")
        admin["PGDATABASE"] = "tracker20"
        sql("grant create on schema public to lived_owner")
        schema(1, "lived_installer", "install", "--worker", "lived_worker", "--request", "lived_request")
        worker, _ = start(1, True)
        current, current_port = start(1)
        request(current_port, "POST", "/projects/seed-project", {"name": "Original project"})
        request(current_port, "POST", "/members/seed-member", {"name": "Original member"})
        request(current_port, "POST", "/tasks/seed-task", {"projectId": "seed-project", "title": "Seed task", "content": "seed-content"})
        seeded = time.monotonic()
        for index in range(seed_tasks):
            request(current_port, "POST", f"/tasks/stress-{index:06}", {"projectId": "seed-project", "title": "Stress task", "content": "stress-content"})
        (output / "seed-workload.json").write_text(json.dumps({"extraTasks": seed_tasks, "seedSeconds": time.monotonic()-seeded, "artifacts": str(artifacts)}, indent=2)+"\n")
        expected = "seed-content"
        identity = sql("select database_uuid::text from tracker.tesl_schema_meta")
        for version in range(1, through+1):
            began = time.monotonic()
            (output / f"v{version}").mkdir(exist_ok=True)
            predecessor, previous_port = (current, current_port) if version > 1 else (None, None)
            if version > 1:
                edit(previous_port, f"before-v{version}")
                expected = f"before-v{version}"
                if version in (7, 13, 15):
                    edit(previous_port, "blocked" if version != 15 else expected, "blocked" if version == 15 else "Seed task")
                stop(worker)
                worker, _ = start(version, True)
                current, current_port = start(version)
                if version in (7, 13, 15):
                    refused = schema(version, "lived_worker", "contract", f"V{version}", ok=False)
                    assert refused.returncode != 0 and ("reject" in refused.stderr.lower() or "quarantin" in refused.stderr.lower()), refused.stderr
                    assert sql("select min_version from tracker.tesl_schema_state") == str(version-1)
                    edit(previous_port, expected)
                    wait(lambda: request(current_port, "GET", "/tasks/seed-task")["content"] == expected)
                # Both binary versions perform writes during every overlap.
                expected = f"overlap-v{version}"
                edit(previous_port, expected)
                wait(lambda: request(current_port, "GET", "/tasks/seed-task")["content"] == expected)
                edit(current_port, expected)
                assert request(previous_port, "GET", "/tasks/seed-task")["content"] == expected
            if version == 6:
                request(current_port, "POST", "/audits/seed-audit", {"name": "Original audit"})
            api_env = dict(appenv("lived_request"), LIVED_API_DATABASE="1", LIVED_EXPECT_CONTENT=expected)
            tests = command([artifacts / f"v{version}/api.test", "-test.run", "^TestTeslApi", "-test.v", "-test.timeout=60s"], env=api_env, timeout=90)
            (output / f"v{version}/api-postgres.log").write_text(tests)
            count = 4 if version < 6 else 5
            if "postgres-api-tests: retained database bound" not in tests or tests.count("--- PASS: TestTeslApi") != count or "--- SKIP:" in tests:
                raise RuntimeError(f"V{version} API suite did not execute all {count} PostgreSQL cases:\n{tests}")
            verify_cohorts(current_port, version)
            if predecessor:
                verify_cohorts(previous_port, version-1)
            stop(predecessor)
            if version in TRANSFORMS:
                before = sql("select row_to_json(s)::text from tracker.tesl_schema_state s")
                refused = schema(version, "lived_worker", "close-epoch", "--through", f"V{version}", "--force", ok=False)
                assert refused.returncode != 0, "epoch closure must not replace a transforming Contract"
                assert sql("select row_to_json(s)::text from tracker.tesl_schema_state s") == before
                schema(version, "lived_worker", "contract", f"V{version}")
                schema(version, "lived_worker", "contract", f"V{version}")
            elif version > 1:
                before = sql("select row_to_json(s)::text from tracker.tesl_schema_state s")
                schema(version, "lived_worker", "close-epoch", "--through", f"V{version}", "--force", "--dry-run")
                assert sql("select row_to_json(s)::text from tracker.tesl_schema_state s") == before
                schema(version, "lived_worker", "close-epoch", "--through", f"V{version}", "--force")
                schema(version, "lived_worker", "close-epoch", "--through", f"V{version}", "--force")
            assert sql("select current||','||min_version||','||compat_floor from tracker.tesl_schema_state") == f"{version},{version},{version}"
            assert sql("select database_uuid::text from tracker.tesl_schema_meta") == identity
            enrich_and_verify(version)
            # Reopen the surviving Request binary after each finality boundary.
            stop(current)
            current, current_port = start(version)
            verify_cohorts(current_port, version)
            if seed_tasks:
                for index in sorted({0, seed_tasks//2, seed_tasks-1}):
                    item = request(current_port, "GET", f"/tasks/stress-{index:06}")
                    assert item["title"] == "Stress task" and item["content"] == "stress-content", item
                metadata = "metadata" if version < 7 else "metadata__v7" if version < 13 else "metadata__v13"
                key = "text" if version < 13 else "body"
                assert int(sql(f"select count(*) from tracker.tasks where id like 'stress-%' and title='Stress task' and {metadata}->>'{key}'='stress-content'")) == seed_tasks
            record = {"version": version, "change": RELEASES[version], "apiTests": count, "cohorts": version, "extraTasks": seed_tasks, "seconds": time.monotonic()-began, "databaseUUID": identity}
            evidence.append(record)
            (output / "rollout.json").write_text(json.dumps(evidence, indent=2)+"\n")
            print(f"PASS V{version}: {count} Tesl API tests, {version} retained cohorts, overlap, finality and restart", flush=True)
        counts = {table: int(sql(f"select count(*) from tracker.{table}")) for table in ("projects", "tasks", "members")}
        assert counts == {"projects": through+1, "members": through+1, "tasks": through+1+seed_tasks}, counts
        if through >= 6:
            assert int(sql("select count(*) from tracker.audits")) == through-4
        print(f"PASS: V1–V{through} retained multi-table PostgreSQL lifecycle", flush=True)
    finally:
        for proc, log in reversed(processes):
            stop(proc)
            log.close()
        subprocess.run(["pg_ctl", "-D", str(data), "-m", "immediate", "-w", "stop"], capture_output=True)
        shutil.rmtree(data)
        shutil.rmtree(sockets)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, default=ROOT / "compiler/_build/default/bin/main.exe")
    parser.add_argument("--through", type=int, default=20)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--run-built", action="store_true")
    parser.add_argument("--resume-build", action="store_true")
    parser.add_argument("--recompile-from", type=Path, help="rebuild exact hash-verified source snapshots from a prior run")
    parser.add_argument("--seed-tasks", type=int, default=0, help="additional V1 tasks created through HTTP for row-volume measurement (0–10000)")
    parser.add_argument("--evidence", type=Path, help="separate rollout logs from immutable built releases")
    args = parser.parse_args()
    if not 1 <= args.through <= 20 or args.build_only and args.run_built:
        parser.error("choose 1–20 versions and either build-only or run-built")
    if not 0 <= args.seed_tasks <= 10000:
        parser.error("--seed-tasks must be between 0 and 10000")
    output, compiler = args.output.resolve(), args.compiler.resolve()
    if output.exists() and not (args.run_built or args.resume_build):
        parser.error("use a new output directory, --run-built or --resume-build")
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, TESL_REPO_ROOT=str(ROOT))
    if not args.run_built:
        build(output, compiler, env, args.through, args.resume_build, args.recompile_from.resolve() if args.recompile_from else None)
    if not args.build_only:
        exercise(output, env, args.through, args.evidence.resolve() if args.evidence else None, args.seed_tasks)


if __name__ == "__main__":
    main()

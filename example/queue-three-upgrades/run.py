#!/usr/bin/env python3
"""Frozen ordinary queue applications: three conversion/repair/retirement edges."""
import argparse
import json
import os
from pathlib import Path
import runpy
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

EXAMPLE = Path(__file__).resolve().parent
REPO = EXAMPLE.parents[1]
# Share the guarded public compiler-preview consumer with the row-data example.
COMMON = runpy.run_path(str(EXAMPLE.parent / "db-three-upgrades/run.py"))
command, apply_preview, eventually = (COMMON[n] for n in ("command", "apply_preview", "eventually"))


def build(output, compiler, env, upgrade_compiler=None, incompatible_compiler=None):
    original_compiler = compiler
    source = output / "source"
    shutil.copytree(EXAMPLE / "schema", source / "schema")
    shutil.copyfile(EXAMPLE / "tesl.toml", source / "tesl.toml")
    app = (EXAMPLE / "app.tesl").read_text()
    entry = source / "app.tesl"
    entry.write_text(app)

    def release(name, release_source=None, release_compiler=None):
        selected_source = source if release_source is None else release_source
        selected_compiler = compiler if release_compiler is None else release_compiler
        selected_entry = selected_source / "app.tesl"
        target = output / name
        target.mkdir()
        for file in sorted(selected_source.rglob("*.tesl")):
            context = json.loads(command([selected_compiler, "agent-context", file], env=env))
            if not context["ok"]:
                raise RuntimeError(json.dumps(context))
        shutil.copytree(selected_source, target / "source")
        command([selected_compiler, "--backend", "go", selected_entry, "--out", target / "go"], env=env)
        command(["go", "test", "-race", "-p", "1", "./..."], cwd=target / "go", env=env, timeout=180)
        command(["go", "build", "-race", "-o", target / "app", "./cmd/app"], cwd=target / "go", env=env)
        if name == "v4":
            command(["go", "build", "-race", "-tags", "tesl_migration_test", "-o", target / "app-test", "./cmd/app"], cwd=target / "go", env=env)
        print(f"Built {name}", flush=True)

    release("v1")
    frozen_original = None
    if incompatible_compiler is not None:
        incompatible_source = output / "incompatible-source"
        shutil.copytree(source, incompatible_source)
        release("v1-incompatible", incompatible_source, incompatible_compiler)
    for version in (2, 3, 4):
        apply_preview(compiler, entry, env, "generate", "--new-revision")
        if version == 2 and upgrade_compiler is not None:
            # A freezes its original schema/closure. B must consume those exact
            # bytes; do not rebuild V1 or substitute compiler-owned history.
            compiler = upgrade_compiler
            frozen_original = (source / "schema/mail/v1.tesl").read_bytes()
        shutil.copyfile(EXAMPLE / f"versions/v{version}.tesl", source / "schema/mail/v-current.tesl")
        helper = f"Schema.Mail.Migrate.Convert{version}"
        old = f"Schema.Mail.V{version - 1}"
        subject, accepted, repaired, fixture, rejected = {
            2: ("text", "body: old.text, priority: 7", 'body: "repaired", priority: 9', 'text: "kept"', 'text: ""'),
            3: ("body", 'content: old.body, importance: old.priority + 10, tag: "v3"', 'content: "repaired", importance: old.priority + 10, tag: "v3"', 'body: "kept", priority: 7', 'body: "", priority: 3'),
            4: ("content", "message: old.content, rank: old.importance + 10, audit: old.tag", 'message: "repaired", rank: old.importance + 10, audit: old.tag', 'content: "kept", importance: 17, tag: "v3"', 'content: "", importance: 5, tag: "v3"'),
        }[version]
        (source / f"migrations/mail/convert{version}.tesl").write_text(f'''module {helper} exposing [convert, repair, oldJob, rejectedJob]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Migration exposing [Migrated(..)]
import {old}
import Schema.Mail.VCurrent
fn convert(old: {old}.Delivery) -> Migrated Schema.Mail.VCurrent.Delivery =
  if old.{subject} == "" then
    Reject "empty payload"
  else
    Row (Schema.Mail.VCurrent.Delivery {{ {accepted} }})
fn repair(old: {old}.Delivery) -> Migrated Schema.Mail.VCurrent.Delivery =
  Row (Schema.Mail.VCurrent.Delivery {{ {repaired} }})
fn oldJob() -> {old}.Delivery = {old}.Delivery {{ {fixture} }}
fn rejectedJob() -> {old}.Delivery = {old}.Delivery {{ {rejected} }}
''')
        edge = source / f"migrations/mail/v{version}.tesl"
        header = edge.read_text().split("module ", 1)[0]
        edge.write_text(header + f'''module Schema.Mail.Migrate.V{version} exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..)]
import {old}
import Schema.Mail.VCurrent
import {helper}
migration = Migration {{
  from: {old}
  to: Schema.Mail.VCurrent
  same: []
  entities: {{}}
  jobs: {{ Delivery: Migrate {helper}.convert }}
  fixtures: [{helper}.oldJob]
}}
''')
        apply_preview(compiler, entry, env, "generate")
        if version == 2 and upgrade_compiler is not None:
            release("v2-original-compiler", release_compiler=original_compiler)
        release(f"v{version}")
        repair = f"Schema.Mail.Migrate.Repair{version}"
        (source / f"migrations/mail/repair{version}.tesl").write_text(f'''module {repair} exposing [repair]
import Tesl.Migration exposing [QueueRepair]
import Schema.Mail.Migrate.V{version}
import {helper}
repair = QueueRepair {{ predecessor: Schema.Mail.Migrate.V{version}.migration, job: "Delivery", revision: 1, migrate: {helper}.repair, fixtures: [{helper}.rejectedJob] }}
''')
        entry.write_text(app.replace("import Tesl.Prelude", f"import {repair}\nimport Tesl.Prelude"))
        release(f"v{version}-repair")
        entry.write_text(app)
        if frozen_original is not None and (source / "schema/mail/v1.tesl").read_bytes() != frozen_original:
            raise RuntimeError("compiler upgrade rewrote the original frozen V1 source")
    entry.write_text(app.replace("import Tesl.Prelude", "import Schema.Mail.Migrate.Repair2\nimport Schema.Mail.Migrate.Repair3\nimport Schema.Mail.Migrate.Repair4\nimport Tesl.Prelude"))
    release("v4-catchup-repair")


def exercise(output, env, catchup_from=None, crash=None):
    cluster = Path(tempfile.mkdtemp(prefix="tesl-queue-three-"))
    data = cluster / "data"
    processes = []
    base = dict(env, PGHOST=str(cluster), PGUSER="demo_installer", PGDATABASE="postgres")

    def sql(statement, login="demo_installer"):
        return command(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atc", statement], env=dict(base, PGUSER=login)).strip()

    def app_env(login):
        return dict(env, DEMO_HOST=str(cluster), DEMO_PORT="5432", DEMO_DB=base["PGDATABASE"], DEMO_USER=login,
                    DEMO_OWNER="demo_owner", DEMO_WORKER="demo_worker", DEMO_REQUEST="demo_request",
                    DEMO_DDL=f"host={cluster} dbname={base['PGDATABASE']} user={login}", DEMO_HTTP_PORT="8097")

    def schema(release, login, *args, refuse=False):
        result = subprocess.run([str(output / release / "app"), "--schema", *args, "--json"], env=app_env(login), text=True, capture_output=True, timeout=60)
        if (result.returncode == 0) == refuse:
            raise RuntimeError(f"unexpected schema outcome {release} {args}: {result.stdout}\n{result.stderr}")
        return result.stdout + result.stderr

    def install(release, refuse=False):
        return schema(release, "demo_installer", "install", "--worker", "demo_worker", "--request", "demo_request", refuse=refuse)

    def stop(proc):
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)

    def worker(release):
        log = open(output / f"{release}-worker.log", "w+")
        proc = subprocess.Popen([str(output / release / "app"), "--schema", "worker", "--json"], env=app_env("demo_worker"), stdout=log, stderr=log)
        processes.append((proc, log))
        def ready():
            log.flush(); log.seek(0)
            text = log.read()
            if proc.poll() is not None:
                raise RuntimeError(text)
            return "schema-worker-ready" in text
        eventually(ready)
        return proc

    def enqueue(version, identity, payload):
        encoded = json.dumps(payload).replace("'", "''")
        sql(f"select mail.tesl_queue_enqueue({version},'Jobs','Delivery','{identity}','{encoded}'::jsonb)", "demo_request")

    def interrupt_at(boundary, mode, login, *args):
        path = cluster / "boundary.sock"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(path))
            listener.listen(16)
            listener.settimeout(1)
            log = open(output / f"catchup-{boundary}.log", "w+")
            proc = subprocess.Popen([str(output / "v4/app-test"), "--schema", mode, *args, "--json"],
                                    env=dict(app_env(login), TESL_MIGRATION_TEST_SOCKET=str(path)), stdout=log, stderr=log)
            processes.append((proc, log))
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(f"process exited before {boundary}: {log.read()}")
                try:
                    connection, _ = listener.accept()
                except TimeoutError:
                    continue
                with connection:
                    connection.settimeout(5)
                    with connection.makefile("rb") as stream:
                        event = json.loads(stream.readline())
                    if event["name"] == boundary:
                        proc.kill()
                        proc.wait(timeout=5)
                        return
                    connection.sendall(b"continue\n")
            raise RuntimeError(f"process did not reach {boundary}")

    try:
        command(["initdb", "-D", data, "-U", "demo_installer", "--auth=trust", "--no-locale", "--encoding=UTF8"])
        command(["pg_ctl", "-D", data, "-l", cluster / "postgres.log", "-o", f"-k {cluster} -h ''", "-w", "start"])
        sql("create role demo_owner nologin; create role demo_worker login; create role demo_request login")
        sql("create database queue_upgrades")
        sql("grant create on database queue_upgrades to demo_owner")
        base["PGDATABASE"] = "queue_upgrades"
        sql("grant create on schema public to demo_owner")
        schema("v2", "demo_request", "install", "--worker", "demo_worker", "--request", "demo_request", refuse=True)
        assert sql("select to_regnamespace('mail') is null") == "t"
        if catchup_from == 0:
            install("v4")
            assert sql("select current from mail.tesl_schema_state") == "0"
            result = json.loads(schema("v4", "demo_worker", "catch-up"))
            assert result["currentVersion"] == 4 and result["minVersion"] == 4, result
            assert sql("select initial_version from mail.tesl_schema_meta") == "1"
            assert sql("select count(*) from mail.tesl_row_queue_retirements") == "3"
            print("PASS: latest V4 queue artifact installs original V1 and catches up on a fresh database", flush=True)
            return
        install("v1")
        active = worker("v1")
        identity = sql("select database_uuid::text from mail.tesl_schema_meta")
        enqueue(1, "retained", {"oldText": "kept"})
        if catchup_from is not None:
            stop(active)
            for version in range(2, catchup_from + 1):
                install(f"v{version}")
                active = worker(f"v{version}")
                eventually(lambda: sql(f"select schema_version={version} from mail.tesl_jobs where id='retained'") == "t")
                stop(active)
                schema(f"v{version}", "demo_worker", "contract", f"V{version}")
            before = sql("select row_to_json(s)::text from mail.tesl_schema_state s")
            refused = schema("v4", "demo_worker", "catch-up", refuse=True)
            assert "staged authority" in refused, refused
            assert sql("select row_to_json(s)::text from mail.tesl_schema_state s") == before
            schema("v4", "demo_worker", "install", "--worker", "demo_worker", "--request", "demo_request", refuse=True)
            if crash == "queue-catchup-after-staging-batch":
                interrupt_at(crash, "install", "demo_installer", "--worker", "demo_worker", "--request", "demo_request")
                assert sql("select row_to_json(s)::text from mail.tesl_schema_state s") == before
            install("v4")
            install("v4")
            assert sql("select row_to_json(s)::text from mail.tesl_schema_state s") == before
            if catchup_from == 2:
                assert sql("select job_id from mail.tesl_queue_claim(2,'Jobs','pending','catchup-old-claimant',15000)", "demo_request") == "retained"
                claimed = sql("select payload::text from mail.tesl_jobs where id='retained'")
                refused = schema("v4", "demo_worker", "catch-up", refuse=True)
                assert "claims" in refused, refused
                assert sql("select min_version from mail.tesl_schema_state") == "2"
                assert sql("select payload::text from mail.tesl_jobs where id='retained'") == claimed
                time.sleep(16)
            if catchup_from == 3:
                # Use the real Request heartbeat operation, then let it expire;
                # never mutate the protected instance table to bypass the guard.
                sql("set application_name='tesl-app:queue-catchup-old'; select mail.tesl_heartbeat(3,1,3)", "demo_request")
                refused = schema("v4", "demo_worker", "catch-up", refuse=True)
                assert "stop those" in refused, refused
                assert sql("select row_to_json(s)::text from mail.tesl_schema_state s") == before
                time.sleep(31)
            if crash is not None and crash != "queue-catchup-after-staging-batch":
                interrupt_at(crash, "catch-up", "demo_worker")
            if catchup_from == 1 and crash is None:
                enqueue(1, "rejected", {"oldText": ""})
                refused = schema("v4", "demo_worker", "catch-up", refuse=True)
                assert "QueueRepair" in refused, refused
                assert sql("select min_version from mail.tesl_schema_state") == "1"
                assert json.loads(sql("select payload from mail.tesl_jobs where id='rejected'")) == {"oldText": ""}
                install("v4-catchup-repair")
                repair_state = sql("select row_to_json(s)::text from mail.tesl_schema_state s")
                refused = schema("v4", "demo_worker", "catch-up", refuse=True)
                assert "not linked" in refused, refused
                assert sql("select row_to_json(s)::text from mail.tesl_schema_state s") == repair_state
            release = "v4-catchup-repair" if catchup_from == 1 and crash is None else "v4"
            result = json.loads(schema(release, "demo_worker", "catch-up"))
            assert result["currentVersion"] == 4 and result["minVersion"] == 4, result
            assert json.loads(sql("select payload from mail.tesl_jobs where id='retained'")) == {"message": "kept", "rank": 27, "audit": "v3"}
            assert sql("select count(*) from mail.tesl_row_queue_conversion_receipts where job_id='retained' and kind='converted'") == "3"
            assert sql("select database_uuid::text from mail.tesl_schema_meta") == identity
            receipts = sql("select json_agg(r order by job_id,source_digest) from mail.tesl_row_queue_conversion_receipts r")
            assert json.loads(schema(release, "demo_worker", "catch-up")) == result
            assert sql("select json_agg(r order by job_id,source_digest) from mail.tesl_row_queue_conversion_receipts r") == receipts
            print(f"PASS: V{catchup_from} → V4 queue catch-up using only the latest binary; payloads, source receipts and replay preserved", flush=True)
            if crash is not None:
                print(f"PASS: queue catch-up resumes process death at {crash}", flush=True)
            return
        if (output / "v1-incompatible/app").exists():
            before = sql("select row_to_json(s)::text from mail.tesl_schema_state s")
            install("v1-incompatible", refuse=True)
            assert sql("select row_to_json(s)::text from mail.tesl_schema_state s") == before
            assert sql("select payload->>'oldText' from mail.tesl_jobs where id='retained'") == "kept"
        first_receipt = None
        for version in (2, 3, 4):
            stop(active)
            rejected = {2: {"oldText": ""}, 3: {"message": "", "priority": 3}, 4: {"content": "", "importance": 5, "tag": "v3"}}[version]
            enqueue(version - 1, f"reject-{version}", rejected)
            install(f"v{version}")
            install(f"v{version}")
            schema(f"v{version}", "demo_worker", "contract", f"V{version}", refuse=True)
            active = worker(f"v{version}")
            eventually(lambda: sql(f"select schema_version={version} from mail.tesl_jobs where id='retained'") == "t")
            eventually(lambda: sql(f"select status='quarantined' and schema_version={version - 1} from mail.tesl_jobs where id='reject-{version}'") == "t")
            late = {2: {"oldText": "late"}, 3: {"message": "late", "priority": 7}, 4: {"content": "late", "importance": 17, "tag": "v3"}}[version]
            enqueue(version - 1, f"late-{version}", late)
            eventually(lambda: sql(f"select schema_version={version} from mail.tesl_jobs where id='late-{version}'") == "t")
            schema(f"v{version}", "demo_worker", "contract", f"V{version}", refuse=True)
            assert sql("select min_version::text||','||compat_floor::text from mail.tesl_schema_state") == f"{version - 1},{version - 1}"
            if version < 4:
                install(f"v{version + 1}")
                # Future staging grants no activation or admission before the
                # actual predecessor has completed conversion and retirement.
                schema(f"v{version + 1}", "demo_worker", "worker", refuse=True)
                assert sql("select current from mail.tesl_schema_state") == str(version)
            stop(active)
            install(f"v{version}-repair")
            active = worker(f"v{version}-repair")
            eventually(lambda: sql(f"select schema_version={version} and status='pending' from mail.tesl_jobs where id='reject-{version}'") == "t")
            stop(active)
            schema(f"v{version}-repair", "demo_worker", "contract", f"V{version}")
            schema(f"v{version}-repair", "demo_worker", "contract", f"V{version}")
            assert sql("select min_version::text||','||compat_floor::text from mail.tesl_schema_state") == f"{version},{version}"
            assert sql("select database_uuid::text from mail.tesl_schema_meta") == identity
            receipts = sql("select string_agg(row_to_json(r)::text,'|' order by source_digest) from mail.tesl_row_queue_conversion_receipts r where job_id='retained' and original::jsonb ? 'oldText'")
            if first_receipt is None:
                first_receipt = receipts
            assert receipts == first_receipt
            active = worker(f"v{version}-repair")
            # A valid rehash cannot substitute a different prior retirement.
            # The successor must compare the complete installed canonical receipt.
            if version < 4:
                stop(active)
                original = sql(f"select encode(retirement,'hex')||','||retirement_hash from mail.tesl_row_queue_retirements where version={version}")
                document, digest = original.split(",")
                sql(f"update mail.tesl_row_queue_retirements set retirement=retirement||convert_to('changed','UTF8'),retirement_hash=encode(sha256(retirement||convert_to('changed','UTF8')),'hex') where version={version}")
                staged = sql(f"select count(*) from mail.tesl_row_queue_conversion_staging where to_version={version + 1}")
                install(f"v{version + 1}", refuse=True)
                assert sql(f"select count(*) from mail.tesl_row_queue_conversion_staging where to_version={version + 1}") == staged
                sql(f"update mail.tesl_row_queue_retirements set retirement=decode('{document}','hex'),retirement_hash='{digest}' where version={version}")
            print(f"V{version - 1} → V{version}: public conversion, rejection, repair, retirement and restart passed", flush=True)
        assert json.loads(sql("select payload from mail.tesl_jobs where id='retained'")) == {"message": "kept", "rank": 27, "audit": "v3"}
        assert sql("select count(*) from mail.tesl_row_queue_retirements") == "3"
        assert sql("select count(*) from mail.tesl_row_queue_conversion_staging") == "6"
        assert sql("select count(*) from mail.tesl_jobs") == "7"
        # Start the ordinary current Request application. Its actual typed queue
        # handler decodes, processes and acknowledges every retained payload.
        number = COMMON["port"]()
        log = open(output / "v4-request.log", "w+")
        proc = subprocess.Popen([str(output / "v4-repair/app")], env=dict(app_env("demo_request"), DEMO_HTTP_PORT=str(number)), stdout=log, stderr=log)
        processes.append((proc, log))
        def serving():
            if proc.poll() is not None:
                log.flush(); log.seek(0)
                raise RuntimeError(log.read())
            with urllib.request.urlopen(f"http://127.0.0.1:{number}/health", timeout=2) as response:
                return json.loads(response.read()) == "ready"
        eventually(serving)
        eventually(lambda: sql("select count(*) from mail.tesl_jobs") == "0")
        assert sql("select string_agg(row_to_json(r)::text,'|' order by source_digest) from mail.tesl_row_queue_conversion_receipts r where job_id='retained' and original::jsonb ? 'oldText'") == first_receipt
        if (output / "v2-original-compiler/app").exists():
            # A different compatible compiler may create a new edge, but cannot
            # substitute executable identity for A's already active V2 edge.
            sql("create database queue_pinned")
            sql("grant create on database queue_pinned to demo_owner")
            base["PGDATABASE"] = "queue_pinned"
            sql("grant create on schema public to demo_owner")
            install("v1")
            original_worker = worker("v1")
            stop(original_worker)
            enqueue(1, "pinned", {"oldText": "original"})
            install("v2-original-compiler")
            original_worker = worker("v2-original-compiler")
            eventually(lambda: sql("select schema_version=2 from mail.tesl_jobs where id='pinned'") == "t")
            stop(original_worker)
            before = sql("select row_to_json(s)::text from mail.tesl_schema_state s")
            receipt = sql("select row_to_json(r)::text from mail.tesl_row_queue_conversion_receipts r")
            install("v2", refuse=True)
            schema("v2", "demo_worker", "worker", refuse=True)
            assert sql("select row_to_json(s)::text from mail.tesl_schema_state s") == before
            assert sql("select row_to_json(r)::text from mail.tesl_row_queue_conversion_receipts r") == receipt
            schema("v2-original-compiler", "demo_worker", "contract", "V2")
            pinned_uuid = sql("select database_uuid::text from mail.tesl_schema_meta")
            install("v4")
            schema("v4", "demo_worker", "catch-up")
            assert json.loads(sql("select payload from mail.tesl_jobs where id='pinned'")) == {"message": "original", "rank": 27, "audit": "v3"}
            assert sql("select database_uuid::text from mail.tesl_schema_meta") == pinned_uuid
            print("Compatible compiler B cannot replace compiler A's active edge; incompatible C refuses", flush=True)
        print("PASS: three ordinary non-additive queue upgrades on one PostgreSQL database", flush=True)
    finally:
        for proc, log in reversed(processes):
            stop(proc); log.close()
        subprocess.run(["pg_ctl", "-D", str(data), "-m", "immediate", "-w", "stop"], capture_output=True)
        if (cluster / "postgres.log").exists():
            shutil.copyfile(cluster / "postgres.log", output / f"postgres-{catchup_from if catchup_from is not None else 'adjacent'}.log")
        shutil.rmtree(cluster)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run-built", action="store_true")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--catch-up-only", action="store_true")
    parser.add_argument("--compiler", type=Path, default=REPO / "compiler/_build/default/bin/main.exe")
    parser.add_argument("--upgrade-compiler", type=Path, help="freeze V1 with --compiler, then build V2–V4 with this compiler")
    parser.add_argument("--incompatible-compiler", type=Path, help="build a fresh V1 whose stored-value incompatibility must refuse the installed database")
    args = parser.parse_args()
    output = args.output.absolute()
    if args.run_built and args.build_only:
        parser.error("--run-built and --build-only cannot be combined")
    if output.exists() and not args.run_built:
        parser.error("output directory must not already exist")
    env = dict(os.environ, TESL_REPO_ROOT=str(REPO))
    if not args.run_built:
        output.mkdir(parents=True)
        build(output, args.compiler.absolute(), env,
              None if args.upgrade_compiler is None else args.upgrade_compiler.absolute(),
              None if args.incompatible_compiler is None else args.incompatible_compiler.absolute())
    if not args.build_only:
        if not args.catch_up_only:
            exercise(output, env)
        for version in (0, 1, 2, 3):
            exercise(output, env, catchup_from=version)
        for boundary in ("queue-catchup-after-staging-batch", "queue-catchup-after-turn", "queue-catchup-after-retirement"):
            exercise(output, env, catchup_from=1, crash=boundary)


if __name__ == "__main__":
    main()

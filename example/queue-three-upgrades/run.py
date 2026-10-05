#!/usr/bin/env python3
"""Frozen ordinary queue applications: three conversion/repair/retirement edges."""
import argparse
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import urllib.request

EXAMPLE = Path(__file__).resolve().parent
REPO = EXAMPLE.parents[1]
# Share the guarded public compiler-preview consumer with the row-data example.
COMMON = runpy.run_path(str(EXAMPLE.parent / "db-three-upgrades/run.py"))
command, apply_preview, eventually = (COMMON[n] for n in ("command", "apply_preview", "eventually"))


def build(output, compiler, env):
    source = output / "source"
    shutil.copytree(EXAMPLE / "schema", source / "schema")
    shutil.copyfile(EXAMPLE / "tesl.toml", source / "tesl.toml")
    app = (EXAMPLE / "app.tesl").read_text()
    entry = source / "app.tesl"
    entry.write_text(app)

    def release(name):
        target = output / name
        target.mkdir()
        for file in sorted(source.rglob("*.tesl")):
            context = json.loads(command([compiler, "agent-context", file], env=env))
            if not context["ok"]:
                raise RuntimeError(json.dumps(context))
        shutil.copytree(source, target / "source")
        command([compiler, "--backend", "go", entry, "--out", target / "go"], env=env)
        command(["go", "test", "-race", "-p", "1", "./..."], cwd=target / "go", env=env, timeout=180)
        command(["go", "build", "-race", "-o", target / "app", "./cmd/app"], cwd=target / "go", env=env)
        print(f"Built {name}", flush=True)

    release("v1")
    for version in (2, 3, 4):
        apply_preview(compiler, entry, env, "generate", "--new-revision")
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


def exercise(output, env):
    cluster = Path(tempfile.mkdtemp(prefix="tesl-queue-three-"))
    data = cluster / "data"
    processes = []
    base = dict(env, PGHOST=str(cluster), PGUSER="demo_installer", PGDATABASE="postgres")

    def sql(statement, login="demo_installer"):
        return command(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atc", statement], env=dict(base, PGUSER=login)).strip()

    def app_env(login):
        return dict(env, DEMO_HOST=str(cluster), DEMO_PORT="5432", DEMO_DB="queue_upgrades", DEMO_USER=login,
                    DEMO_OWNER="demo_owner", DEMO_WORKER="demo_worker", DEMO_REQUEST="demo_request",
                    DEMO_DDL=f"host={cluster} dbname=queue_upgrades user={login}", DEMO_HTTP_PORT="8097")

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

    try:
        command(["initdb", "-D", data, "-U", "demo_installer", "--auth=trust", "--no-locale", "--encoding=UTF8"])
        command(["pg_ctl", "-D", data, "-l", cluster / "postgres.log", "-o", f"-k {cluster} -h ''", "-w", "start"])
        sql("create role demo_owner nologin; create role demo_worker login; create role demo_request login")
        sql("create database queue_upgrades")
        sql("grant create on database queue_upgrades to demo_owner")
        base["PGDATABASE"] = "queue_upgrades"
        sql("grant create on schema public to demo_owner")
        install("v2", refuse=True)
        assert sql("select to_regnamespace('mail') is null") == "t"
        install("v1")
        active = worker("v1")
        identity = sql("select database_uuid::text from mail.tesl_schema_meta")
        enqueue(1, "retained", {"oldText": "kept"})
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
                install(f"v{version + 1}", refuse=True)
                assert sql(f"select count(*) from mail.tesl_row_queue_conversion_staging where to_version={version + 1}") == "0"
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
                install(f"v{version + 1}", refuse=True)
                assert sql(f"select count(*) from mail.tesl_row_queue_conversion_staging where to_version={version + 1}") == "0"
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
        print("PASS: three ordinary non-additive queue upgrades on one PostgreSQL database", flush=True)
    finally:
        for proc, log in reversed(processes):
            stop(proc); log.close()
        subprocess.run(["pg_ctl", "-D", str(data), "-m", "immediate", "-w", "stop"], capture_output=True)
        shutil.rmtree(cluster)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run-built", action="store_true")
    parser.add_argument("--build-only", action="store_true")
    args = parser.parse_args()
    output = args.output.absolute()
    if args.run_built and args.build_only:
        parser.error("--run-built and --build-only cannot be combined")
    if output.exists() and not args.run_built:
        parser.error("output directory must not already exist")
    env = dict(os.environ, TESL_REPO_ROOT=str(REPO))
    if not args.run_built:
        output.mkdir(parents=True)
        build(output, REPO / "compiler/_build/default/bin/main.exe", env)
    if not args.build_only:
        exercise(output, env)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Public V1 -> row Retype V2 -> queue payload V3, with one latest deployment."""
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

ROOT = Path(__file__).resolve().parents[1]
COMMON = runpy.run_path(str(ROOT / "example/db-three-upgrades/run.py"))
command, preview, eventually = (COMMON[n] for n in ("command", "apply_preview", "eventually"))


def build(output, compiler, env):
    source = output / "source"
    (source / "schema/mail").mkdir(parents=True)
    (source / "tesl.toml").write_text("")
    app = (ROOT / "example/queue-three-upgrades/app.tesl").read_text()
    app = app.replace("[String]", "[String, List]").replace("import Tesl.App", "import Tesl.DB exposing [dbRead]\nimport Tesl.App")
    app = app.replace("exposing [Delivery]", "exposing [Delivery, Note]")
    app = app.replace('api Api { get "/health" -> String }', 'handler get notes() -> List Note requires [dbRead Note] = select note from Note order note.id asc\napi Api { get "/health" -> String, get "/notes" -> List Note }')
    app = app.replace("{ health }", "{ health, notes }")
    app = app.replace("requires [queueRead, envRead]", "requires [queueRead, envRead, dbRead Note]")
    entry = source / "app.tesl"
    entry.write_text(app)
    current = source / "schema/mail/v-current.tesl"
    original = (ROOT / "example/queue-three-upgrades/schema/mail/v-current.tesl").read_text()
    original = original.replace("[Delivery, Jobs]", "[Delivery, Jobs, Note, Metadata]") + '''
record Metadata { text: String }
codec Metadata {
 toJson { text -> "oldText" with_codec stringCodec }
 fromJson [ { text <- "oldText" with_codec stringCodec } ]
}
entity Note table "notes" primaryKey id { id: String, metadata: Metadata }
'''
    current.write_text(original)
    for version in (1, 2, 3):
        if version > 1:
            preview(compiler, entry, env, "generate", "--new-revision")
            if version == 2:
                fresh = original.replace("record Metadata { text: String }", "record Metadata { text: String, extra: String }")
                fresh = fresh.replace('text -> "oldText" with_codec stringCodec }\n fromJson', 'text -> "newText" with_codec stringCodec, extra -> "detail" with_codec stringCodec }\n fromJson')
                fresh = fresh.replace('text <- "oldText" with_codec stringCodec } ]\n}\nentity', 'text <- "newText" with_codec stringCodec, extra <- "detail" with_codec stringCodec } ]\n}\nentity')
                current.write_text(fresh)
                body = '''module Schema.Mail.Migrate.V2 exposing [migration, fixture]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Schema.Mail.V1
import Schema.Mail.VCurrent
migration = Migration {
 from: Schema.Mail.V1
 to: Schema.Mail.VCurrent
 same: []
 entities: { Note: Migrate convert [Retype metadata, WriteBack metadata metadata backward] }
 fixtures: [fixture]
}
fn convert(old: Schema.Mail.V1.Note) -> Migrated Schema.Mail.VCurrent.Note =
 if old.metadata.text == "blocked" then
  Reject "repair the retained row"
 else
  Row (Schema.Mail.VCurrent.Note { id: old.id, metadata: Schema.Mail.VCurrent.Metadata { text: old.metadata.text, extra: "migrated" } })
fn backward(row: Schema.Mail.VCurrent.Note) -> Schema.Mail.V1.Metadata = Schema.Mail.V1.Metadata { text: row.metadata.text }
fn fixture() -> Schema.Mail.V1.Note = Schema.Mail.V1.Note { id: "fixture", metadata: Schema.Mail.V1.Metadata { text: "kept" } }
'''
            else:
                fresh = current.read_text().replace("record Delivery { text: String }", "record Delivery { body: String }")
                fresh = fresh.replace('text -> "oldText"', 'body -> "message"').replace('text <- "oldText"', 'body <- "message"')
                current.write_text(fresh)
                (source / "migrations/mail/convert3.tesl").write_text('''module Schema.Mail.Migrate.Convert3 exposing [convert, fixture]
import Tesl.Migration exposing [Migrated(..)]
import Schema.Mail.V2
import Schema.Mail.VCurrent
fn convert(old: Schema.Mail.V2.Delivery) -> Migrated Schema.Mail.VCurrent.Delivery =
 Row (Schema.Mail.VCurrent.Delivery { body: old.text })
fn fixture() -> Schema.Mail.V2.Delivery = Schema.Mail.V2.Delivery { text: "kept" }
''')
                body = '''module Schema.Mail.Migrate.V3 exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..), Same(..), Migrated(..)]
import Schema.Mail.V2
import Schema.Mail.VCurrent
import Schema.Mail.Migrate.Convert3
migration = Migration {
 from: Schema.Mail.V2
 to: Schema.Mail.VCurrent
 same: [Same Schema.Mail.V2.Metadata Schema.Mail.VCurrent.Metadata]
 entities: {}
 jobs: { Delivery: Migrate Schema.Mail.Migrate.Convert3.convert }
 fixtures: [Schema.Mail.Migrate.Convert3.fixture]
}
'''
            edge = source / f"migrations/mail/v{version}.tesl"
            header = edge.read_text().split("module ", 1)[0]
            edge.write_text(header + body)
            preview(compiler, entry, env, "generate")
            if version == 2:
                preview(compiler, entry, env, "contract", "--version", "2")
        for path in sorted(source.rglob("*.tesl")):
            assert json.loads(command([compiler, "agent-context", path], env=env))["ok"]
        release = output / f"v{version}"
        release.mkdir()
        shutil.copytree(source, release / "source")
        command([compiler, "--backend", "go", entry, "--out", release / "go"], env=env)
        command(["go", "test", "-race", "./..."], cwd=release / "go", env=env, timeout=180)
        command(["go", "build", "-race", "-o", release / "app", "./cmd/app"], cwd=release / "go", env=env)
        if version == 3:
            command(["go", "build", "-race", "-tags", "tesl_migration_test", "-o", release / "app-test", "./cmd/app"], cwd=release / "go", env=env)
        print(f"Built ordered row/queue V{version}", flush=True)

    preview(compiler, entry, env, "generate", "--new-revision")
    preview(compiler, entry, env, "generate")
    release = output / "v4"
    release.mkdir()
    shutil.copytree(source, release / "source")
    for path in sorted(source.rglob("*.tesl")):
        assert json.loads(command([compiler, "agent-context", path], env=env))["ok"]
    command([compiler, "--backend", "go", entry, "--out", release / "go"], env=env)
    command(["go", "test", "-race", "./..."], cwd=release / "go", env=env, timeout=180)
    command(["go", "build", "-race", "-o", release / "app", "./cmd/app"], cwd=release / "go", env=env)
    print("Built additive V4 after ordered row/queue history", flush=True)
    missing = output / "no-contract"
    shutil.copytree(output / "v2/source", missing / "source")
    (missing / "source/migrations/mail/v2-contract.tesl").unlink()
    for path in sorted((missing / "source").rglob("*.tesl")):
        assert json.loads(command([compiler, "agent-context", path], env=env))["ok"]
    command([compiler, "--backend", "go", missing / "source/app.tesl", "--out", missing / "go"], env=env)
    command(["go", "build", "-race", "-o", missing / "app", "./cmd/app"], cwd=missing / "go", env=env)

def check_combined(output, compiler, env):
    bad = Path(tempfile.mkdtemp(prefix="combined-", dir=output))
    shutil.copytree(output / "v3/source", bad, dirs_exist_ok=True)
    bad_schema = bad / "schema/mail/v-current.tesl"
    bad_schema.write_text(bad_schema.read_text().replace("id: String, metadata:", "id: String, label: String, metadata:"))
    edge = bad / "migrations/mail/v3.tesl"
    edge.write_text(edge.read_text().replace("exposing [migration]", "exposing [migration, oldNote]").replace("entities: {}", "entities: { Note: Migrate copy [] }").replace("fixtures: [Schema.Mail.Migrate.Convert3.fixture]", "fixtures: [Schema.Mail.Migrate.Convert3.fixture, oldNote]") + '''
fn copy(old: Schema.Mail.V2.Note) -> Migrated Schema.Mail.VCurrent.Note =
 Row (Schema.Mail.VCurrent.Note { id: old.id, label: "new", metadata: old.metadata })
fn oldNote() -> Schema.Mail.V2.Note = Schema.Mail.V2.Note { id: "fixture", metadata: Schema.Mail.V2.Metadata { text: "kept", extra: "migrated" } }
''')
    result = subprocess.run([str(compiler), "migrate", "generate", str(bad / "app.tesl"), "--manifest-json"], env=env, text=True, capture_output=True, timeout=120)
    diagnostic = json.loads(result.stdout)
    text = json.dumps(diagnostic)
    assert 'MIG028' in text and "Split these into ordered revisions" in text and "Note" in text and "Jobs.Delivery" in text and "--schema catch-up" in text, text
    print("PASS: combined row/queue change reports the tested split/order and deployment commands", flush=True)


def exercise(output, env, rejection=False, claim=False, crash=None, from_v2=False, epoch_tail=False, deployment=False, fresh=False, terminal_row=False, heartbeat=False, combined_worker=False, claim_status_race=False):
    target = 2 if terminal_row else (4 if epoch_tail else 3)
    cluster = Path(tempfile.mkdtemp(prefix="ordered-", dir=env.get(
        "TESL_MIGRATION_TEST_SOCKET_ROOT", env.get("TESL_MIGRATION_TEST_SOCKET_TMPDIR", "/tmp"))))
    storage = Path(tempfile.mkdtemp(prefix="ordered-data-", dir=env.get(
        "TESL_MIGRATION_TEST_DATA_TMPDIR", env.get("TMPDIR", "/tmp"))))
    data = storage / "data"
    scenario = (f"v{target}-deploy{int(deployment)}-fresh{int(fresh)}-reject{int(rejection)}"
                f"-claim{int(claim)}-heartbeat{int(heartbeat)}-fromv2{int(from_v2)}"
                f"-tail{int(epoch_tail)}-worker{int(combined_worker)}-statusrace{int(claim_status_race)}-{crash or 'no-crash'}")
    processes = []
    base = dict(env, PGHOST=str(cluster), PGPORT="5432", PGUSER="installer", PGDATABASE="postgres")

    def sql(statement, login="installer"):
        return command(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atc", statement], env=dict(base, PGUSER=login)).strip()

    def app_env(login, port=0):
        return dict(env, DEMO_HOST=str(cluster), DEMO_PORT="5432", DEMO_DB="ordered", DEMO_USER=login,
                    DEMO_OWNER="owner", DEMO_WORKER="worker", DEMO_REQUEST="request", DEMO_HTTP_PORT=str(port),
                    DEMO_DDL=f"host={cluster} port=5432 dbname=ordered user={login}")

    status_race_done = False

    def deploy_across_claim_expiry(settings):
        nonlocal status_race_done
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            path = cluster / "status-boundary.sock"
            listener.bind(str(path)); listener.listen(16); listener.settimeout(0.1)
            log = open(output / "claim-status-deploy.log", "w+")
            process = subprocess.Popen(
                [str(output / "v3/app-test"), "--schema", "deploy", "--json"],
                env=dict(settings, TESL_MIGRATION_TEST_SOCKET=str(path)), stdout=log, stderr=log)
            processes.append((process, log))
            deadline = time.monotonic() + 90
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise RuntimeError("controlled claim/status deployment timed out")
                try:
                    connection, _ = listener.accept()
                except TimeoutError:
                    continue
                with connection:
                    connection.settimeout(5)
                    with connection.makefile("rb") as stream:
                        event = json.loads(stream.readline())
                    if event["name"] == "schema-deploy-before-queue-status" and not status_race_done:
                        before = json.loads(sql("select mail.tesl_row_queue_status()", "worker"))
                        assert [b["code"] for b in before["blockers"]] == ["QUEUE_RETIRING_CLAIMS"], before
                        # The Installer moves only the lease clock at this test boundary.
                        # Production catch-up, conversion, fences and receipts remain intact.
                        expired = sql("with expired as (update mail.tesl_jobs set lease_until=clock_timestamp()-interval '1 second' where id='retained' returning id) select id from expired")
                        assert expired == "retained", expired
                        after = json.loads(sql("select mail.tesl_row_queue_status()", "worker"))
                        assert [b["code"] for b in after["blockers"]] == ["QUEUE_OLD_PAYLOADS"], after
                        assert before["oldPayloads"] == after["oldPayloads"] == 1
                        assert before["liveRetiringClaims"] == 1 and after["liveRetiringClaims"] == 0
                        (output / "claim-status-transition.json").write_text(json.dumps({"before": before, "after": after}, indent=2))
                        status_race_done = True
                    connection.sendall(b"continue\n")
            log.flush(); log.seek(0)
            result = subprocess.CompletedProcess(process.args, process.returncode, log.read(), "")
            assert status_race_done, result
            return result

    def schema(version, login, *args, refuse=False, timeout_seconds=75):
        settings = app_env(login)
        if args[0] == "deploy":
            settings["TESL_SCHEMA_INSTALLER_DSN"] = app_env("installer")["DEMO_DDL"]
            settings["TESL_SCHEMA_DEPLOY_TIMEOUT_SECONDS"] = str(timeout_seconds)
        if claim_status_race and not status_race_done and args[0] == "deploy" and not refuse:
            result = deploy_across_claim_expiry(settings)
        else:
            result = subprocess.run([str(output / f"v{version}/app"), "--schema", *args, "--json"], env=settings, capture_output=True, text=True, timeout=90)
        if (result.returncode == 0) == refuse:
            raise RuntimeError(f"V{version} {args}: {result.stdout}\n{result.stderr}")
        return result.stdout + result.stderr

    def installing_worker(version):
        log = open(output / f"installing-worker-v{version}.log", "w+")
        settings = dict(app_env("worker"), TESL_SCHEMA_INSTALLER_DSN=app_env("installer")["DEMO_DDL"])
        process = subprocess.Popen([str(output / f"v{version}/app"), "--schema", "worker", "--install", "--json"], env=settings, stdout=log, stderr=log)
        processes.append((process, log))
        def ready():
            log.flush(); log.seek(0)
            text = log.read()
            if process.poll() is not None:
                raise RuntimeError(f"combined worker exited: {text}")
            return '"kind":"schema-worker-ready"' in text
        eventually(ready)
        assert sql("select count(*) from pg_stat_activity where datname=current_database() and usename='installer' and application_name like 'tesl-exec:%'") == "0"
        assert sql("select has_table_privilege('worker','mail.tesl_schema_state','UPDATE')") == "f"
        return process

    def stop_worker(process):
        process.terminate()
        assert process.wait(timeout=10) == 0

    def interrupt_at(boundary):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            path = cluster / "boundary.sock"
            listener.bind(str(path)); listener.listen(16); listener.settimeout(1)
            log = open(output / f"crash-{boundary}.log", "w+")
            settings = dict(app_env("worker"), TESL_MIGRATION_TEST_SOCKET=str(path))
            if deployment or combined_worker:
                settings["TESL_SCHEMA_INSTALLER_DSN"] = app_env("installer")["DEMO_DDL"]
            arguments = ["worker", "--install"] if combined_worker else ["deploy" if deployment else "catch-up"]
            process = subprocess.Popen([str(output / "v3/app-test"), "--schema", *arguments, "--json"], env=settings, stdout=log, stderr=log)
            processes.append((process, log))
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(f"catch-up exited before {boundary}: {log.read()}")
                try:
                    connection, _ = listener.accept()
                except TimeoutError:
                    continue
                with connection:
                    connection.settimeout(5)
                    with connection.makefile("rb") as stream:
                        event = json.loads(stream.readline())
                    if event["name"] == boundary:
                        if boundary in ("schema-deploy-after-installer-close", "schema-worker-after-installer-close"):
                            assert sql("select count(*) from pg_stat_activity where datname=current_database() and usename='installer' and application_name like 'tesl-exec:%'") == "0"
                        process.kill(); process.wait(timeout=5)
                        return
                    connection.sendall(b"continue\n")
            raise RuntimeError(f"missing boundary {boundary}")

    try:
        command(["initdb", "-D", data, "-U", "installer", "--auth=trust", "--no-locale", "--encoding=UTF8"])
        command(["pg_ctl", "-D", data, "-l", cluster / "postgres.log", "-o", f"-k {cluster} -h ''", "-w", "start"])
        sql('create role owner nologin; create role worker login; create role request login')
        sql('create database ordered;')
        sql('grant create on database ordered to owner')
        base["PGDATABASE"] = "ordered"
        sql('grant create on schema public to owner')
        if deployment:
            settings = dict(app_env("worker"), TESL_SCHEMA_INSTALLER_DSN=app_env("installer")["DEMO_DDL"])
            missing = subprocess.run([str(output / "no-contract/app"), "--schema", "deploy", "--json"], env=settings, capture_output=True, text=True, timeout=30)
            assert missing.returncode != 0 and "reviewed final row Contract" in missing.stderr, missing
            assert sql("select to_regnamespace('mail') is null") == "t"
            # A differently routed Installer must be refused before either
            # database receives application metadata.
            sql("create database other")
            wrong = dict(app_env("worker"), TESL_SCHEMA_INSTALLER_DSN=f"host={cluster} port=5432 dbname=other user=installer")
            result = subprocess.run([str(output / f"v{target}/app"), "--schema", "deploy", "--json"], env=wrong, capture_output=True, text=True, timeout=30)
            assert result.returncode != 0 and "same PostgreSQL database" in result.stderr, result
            assert sql("select to_regnamespace('mail') is null") == "t"
            other = dict(base, PGDATABASE="other")
            assert command(["psql", "-X", "-Atc", "select to_regnamespace('mail') is null"], env=other).strip() == "t"
        if fresh:
            result = json.loads(schema(target, "worker", "deploy"))
            assert result["kind"] == "schema-deployed" and result["currentVersion"] == target, result
            assert sql("select initial_version from mail.tesl_schema_meta") == "1"
            assert json.loads(schema(target, "worker", "deploy")) == result
            print(f"PASS: fresh automatic deployment to V{target} and immutable replay", flush=True)
            return
        if combined_worker:
            stop_worker(installing_worker(1))
        else:
            schema(1, "installer", "install", "--worker", "worker", "--request", "request")
            schema(1, "worker", "catch-up")
        text = "blocked" if rejection else "kept"
        sql(f'''insert into mail.notes(id,metadata) values ('one','{{"oldText":"{text}"}}')''', "request")
        sql('''select mail.tesl_queue_enqueue(1,'Jobs','Delivery','retained','{"oldText":"job-kept"}')''', "request")
        identity = sql("select database_uuid::text from mail.tesl_schema_meta")
        if from_v2:
            schema(2, "worker", "catch-up")
            schema(2, "worker", "contract", "V2")
        if combined_worker:
            worker = installing_worker(2)
            assert sql("select current::text||','||min_version::text from mail.tesl_schema_state") == "2,1"
            sql("select mail.tesl_queue_admit(1,'Jobs')", "request")
            stop_worker(worker)
            schema(2, "worker", "contract", "V2")
            if crash:
                interrupt_at(crash)
                assert sql("select current from mail.tesl_schema_state") == "2"
            worker = installing_worker(3)
            assert sql("select current::text||','||min_version::text from mail.tesl_schema_state") == "3,2"
            eventually(lambda: sql("select schema_version from mail.tesl_jobs where id='retained'") == "3")
            stop_worker(worker)
        elif not deployment:
            schema(target, "installer", "install", "--worker", "worker", "--request", "request")
        assert sql("select current from mail.tesl_schema_state") == ("3" if combined_worker else "2" if from_v2 else "1")
        if crash is not None and not combined_worker:
            interrupt_at(crash)
            committed = crash == "row-contract-after-retirement"
            assert sql("select schema_version from mail.tesl_jobs where id='retained'") == ("2" if committed else "1")
            assert sql("select count(*) from mail.tesl_row_queue_restamps") == ("1" if committed else "0")
            if crash == "row-catchup-after-step":
                # V2 is expanded, but V1 remains admitted. Its ordinary row
                # insert and queue enqueue must survive the eventual Contract.
                sql('''insert into mail.notes(id,metadata) values ('late','{"oldText":"late-row"}')''', "request")
                sql('''select mail.tesl_queue_enqueue(1,'Jobs','Delivery','late-job','{"oldText":"late-job"}')''', "request")
        if claim:
            claim_version = 2 if from_v2 else 1
            assert sql(f"select job_id from mail.tesl_queue_claim({claim_version},'Jobs','pending','old-claimant',15000)", "request") == "retained"
            if not deployment:
                refused = schema(3, "worker", "catch-up", refuse=True)
                assert "leased" in refused, refused
                assert sql("select min_version from mail.tesl_schema_state") == "1"
                assert sql("select schema_version from mail.tesl_jobs where id='retained'") == "1"
                assert sql("select count(*) from mail.tesl_row_queue_restamps") == "0"
                time.sleep(16)
        if heartbeat:
            sql("set application_name='tesl-app:deploy-old'; select mail.tesl_heartbeat(1,1,1)", "request")
            refused = schema(target, "worker", "deploy", refuse=True, timeout_seconds=2)
            assert "deadline" in refused, refused
            assert sql("select current from mail.tesl_schema_state") == "1"
            assert sql("select schema_version from mail.tesl_jobs where id='retained'") == "1"
        if rejection:
            refused = schema(target, "worker", "deploy" if deployment else "catch-up", refuse=True)
            assert "reject" in refused.lower(), refused
            assert sql("select min_version from mail.tesl_schema_state") == "1"
            assert sql("select schema_version from mail.tesl_jobs where id='retained'") == "1"
            sql('''update mail.notes set metadata='{"oldText":"kept"}' where id='one' ''', "request")
        mode = "deploy" if deployment else "catch-up"
        result = json.loads(schema(target, "worker", mode))
        assert result["kind"] == ("schema-deployed" if deployment else "schema-caught-up"), result
        assert result["currentVersion"] == target and result["minVersion"] == (2 if terminal_row else 3), result
        if epoch_tail:
            schema(4, "worker", "close-epoch", "--through", "V4")
            assert sql("select min_version from mail.tesl_schema_state") == "4"
        assert json.loads(sql("select metadata__v2 from mail.notes where id='one'")) == {"newText": "kept", "detail": "migrated"}
        assert json.loads(sql("select payload from mail.tesl_jobs where id='retained'")) == {"oldText" if terminal_row else "message": "job-kept"}
        if crash == "row-catchup-after-step":
            assert json.loads(sql("select metadata__v2 from mail.notes where id='late'")) == {"newText": "late-row", "detail": "migrated"}
            assert json.loads(sql("select payload from mail.tesl_jobs where id='late-job'")) == {"message": "late-job"}
        assert sql("select database_uuid::text from mail.tesl_schema_meta") == identity
        assert sql("select count(*) from mail.tesl_row_queue_restamps where job_id='retained' and from_version=1 and to_version=2") == "1"
        receipts = sql("select json_agg(v order by version,step) from mail.tesl_schema_versions v")
        schema(target, "worker", mode)
        assert sql("select json_agg(v order by version,step) from mail.tesl_schema_versions v") == receipts
        audit = sql("select retirement_hash from mail.tesl_row_queue_restamps where job_id='retained' and from_version=1")
        sql("update mail.tesl_row_queue_restamps set retirement_hash=repeat('0',64) where job_id='retained' and from_version=1")
        refused = schema(target, "worker", mode, refuse=True)
        assert "restamp audit" in refused, refused
        sql(f"update mail.tesl_row_queue_restamps set retirement_hash='{audit}' where job_id='retained' and from_version=1")
        number = COMMON["port"]()
        log = open(output / f"request-{rejection}.log", "w+")
        process = subprocess.Popen([str(output / f"v{target}/app")], env=app_env("request", number), stdout=log, stderr=log)
        processes.append((process, log))
        eventually(lambda: COMMON["request"](number, "GET", "/health") == "ready")
        rows = COMMON["request"](number, "GET", "/notes")
        assert next(row for row in rows if row["id"] == "one")["metadata"] == {"newText": "kept", "detail": "migrated"}, rows
        eventually(lambda: sql("select count(*) from mail.tesl_jobs") == "0")
        print(f"PASS: ordered row/queue latest-binary {mode}; rejection={rejection}, claim={claim}, heartbeat={heartbeat}, crash={crash}, fromV2={from_v2}, epochTail={epoch_tail}, combinedWorker={combined_worker}, claimStatusRace={claim_status_race}; audited restamp, retained row/job and typed handler", flush=True)
    finally:
        for process, log in processes:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=5)
            log.close()
        subprocess.run(["pg_ctl", "-D", str(data), "-m", "immediate", "-w", "stop"], capture_output=True)
        if (cluster / "postgres.log").exists():
            shutil.copyfile(cluster / "postgres.log", output / f"postgres-{scenario}.log")
        shutil.rmtree(cluster)
        shutil.rmtree(storage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run-built", action="store_true")
    parser.add_argument("--deploy-only", action="store_true")
    parser.add_argument("--compiler", type=Path, default=ROOT / "compiler/_build/default/bin/main.exe")
    args = parser.parse_args()
    output = args.output.absolute()
    env = dict(os.environ, TESL_REPO_ROOT=str(ROOT))
    if not args.run_built:
        output.mkdir(parents=True)
        build(output, args.compiler.absolute(), env)
    check_combined(output, args.compiler.absolute(), env)
    if not args.deploy_only:
        exercise(output, env)
        exercise(output, env, rejection=True)
        exercise(output, env, claim=True)
        exercise(output, env, from_v2=True)
        exercise(output, env, epoch_tail=True)
        for boundary in ("row-catchup-after-step", "row-contract-after-retirement-statement", "row-contract-after-retirement"):
            exercise(output, env, crash=boundary)
    exercise(output, env, deployment=True, fresh=True)
    exercise(output, env, deployment=True, terminal_row=True, rejection=True)
    exercise(output, env, deployment=True, claim=True)
    exercise(output, env, deployment=True, heartbeat=True)
    exercise(output, env, deployment=True, from_v2=True)
    exercise(output, env, deployment=True, from_v2=True, claim=True)
    exercise(output, env, deployment=True, crash="schema-deploy-after-installer-close")
    exercise(output, env, combined_worker=True, crash="schema-worker-after-installer-close")
    exercise(output, env, deployment=True, from_v2=True, claim=True, claim_status_race=True)


if __name__ == "__main__":
    main()

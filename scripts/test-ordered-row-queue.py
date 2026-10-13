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


def exercise(output, env, rejection=False, claim=False, crash=None, from_v2=False, epoch_tail=False):
    target = 4 if epoch_tail else 3
    cluster = Path(tempfile.mkdtemp(prefix="ordered-", dir="/tmp"))
    data = cluster / "data"
    processes = []
    base = dict(env, PGHOST=str(cluster), PGPORT="5432", PGUSER="installer", PGDATABASE="postgres")

    def sql(statement, login="installer"):
        return command(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atc", statement], env=dict(base, PGUSER=login)).strip()

    def app_env(login, port=0):
        return dict(env, DEMO_HOST=str(cluster), DEMO_PORT="5432", DEMO_DB="ordered", DEMO_USER=login,
                    DEMO_OWNER="owner", DEMO_WORKER="worker", DEMO_REQUEST="request", DEMO_HTTP_PORT=str(port),
                    DEMO_DDL=f"host={cluster} port=5432 dbname=ordered user={login}")

    def schema(version, login, *args, refuse=False):
        result = subprocess.run([str(output / f"v{version}/app"), "--schema", *args, "--json"], env=app_env(login), capture_output=True, text=True, timeout=90)
        if (result.returncode == 0) == refuse:
            raise RuntimeError(f"V{version} {args}: {result.stdout}\n{result.stderr}")
        return result.stdout + result.stderr

    def interrupt_at(boundary):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            path = cluster / "boundary.sock"
            listener.bind(str(path)); listener.listen(16); listener.settimeout(1)
            log = open(output / f"crash-{boundary}.log", "w+")
            process = subprocess.Popen([str(output / "v3/app-test"), "--schema", "catch-up", "--json"], env=dict(app_env("worker"), TESL_MIGRATION_TEST_SOCKET=str(path)), stdout=log, stderr=log)
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
        schema(1, "installer", "install", "--worker", "worker", "--request", "request")
        schema(1, "worker", "catch-up")
        text = "blocked" if rejection else "kept"
        sql(f'''insert into mail.notes(id,metadata) values ('one','{{"oldText":"{text}"}}')''', "request")
        sql('''select mail.tesl_queue_enqueue(1,'Jobs','Delivery','retained','{"oldText":"job-kept"}')''', "request")
        identity = sql("select database_uuid::text from mail.tesl_schema_meta")
        if from_v2:
            schema(2, "worker", "catch-up")
            schema(2, "worker", "contract", "V2")
        schema(target, "installer", "install", "--worker", "worker", "--request", "request")
        assert sql("select current from mail.tesl_schema_state") == ("2" if from_v2 else "1")
        if crash is not None:
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
            assert sql("select job_id from mail.tesl_queue_claim(1,'Jobs','pending','old-claimant',15000)", "request") == "retained"
            refused = schema(3, "worker", "catch-up", refuse=True)
            assert "leased" in refused, refused
            assert sql("select min_version from mail.tesl_schema_state") == "1"
            assert sql("select schema_version from mail.tesl_jobs where id='retained'") == "1"
            assert sql("select count(*) from mail.tesl_row_queue_restamps") == "0"
            time.sleep(16)
        if rejection:
            refused = schema(3, "worker", "catch-up", refuse=True)
            assert "reject" in refused.lower(), refused
            assert sql("select min_version from mail.tesl_schema_state") == "1"
            assert sql("select schema_version from mail.tesl_jobs where id='retained'") == "1"
            sql('''update mail.notes set metadata='{"oldText":"kept"}' where id='one' ''', "request")
        result = json.loads(schema(target, "worker", "catch-up"))
        assert result["currentVersion"] == target and result["minVersion"] == 3, result
        if epoch_tail:
            schema(4, "worker", "close-epoch", "--through", "V4")
            assert sql("select min_version from mail.tesl_schema_state") == "4"
        assert json.loads(sql("select metadata__v2 from mail.notes where id='one'")) == {"newText": "kept", "detail": "migrated"}
        assert json.loads(sql("select payload from mail.tesl_jobs where id='retained'")) == {"message": "job-kept"}
        if crash == "row-catchup-after-step":
            assert json.loads(sql("select metadata__v2 from mail.notes where id='late'")) == {"newText": "late-row", "detail": "migrated"}
            assert json.loads(sql("select payload from mail.tesl_jobs where id='late-job'")) == {"message": "late-job"}
        assert sql("select database_uuid::text from mail.tesl_schema_meta") == identity
        assert sql("select count(*) from mail.tesl_row_queue_restamps where job_id='retained' and from_version=1 and to_version=2") == "1"
        receipts = sql("select json_agg(v order by version,step) from mail.tesl_schema_versions v")
        schema(target, "worker", "catch-up")
        assert sql("select json_agg(v order by version,step) from mail.tesl_schema_versions v") == receipts
        audit = sql("select retirement_hash from mail.tesl_row_queue_restamps where job_id='retained' and from_version=1")
        sql("update mail.tesl_row_queue_restamps set retirement_hash=repeat('0',64) where job_id='retained' and from_version=1")
        refused = schema(target, "worker", "catch-up", refuse=True)
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
        print(f"PASS: ordered row/queue latest-binary catch-up; rejection={rejection}, claim={claim}, crash={crash}, fromV2={from_v2}, epochTail={epoch_tail}; audited restamp, retained row/job and typed handler", flush=True)
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
            shutil.copyfile(cluster / "postgres.log", output / f"postgres-{rejection}.log")
        shutil.rmtree(cluster)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run-built", action="store_true")
    parser.add_argument("--compiler", type=Path, default=ROOT / "compiler/_build/default/bin/main.exe")
    args = parser.parse_args()
    output = args.output.absolute()
    env = dict(os.environ, TESL_REPO_ROOT=str(ROOT))
    if not args.run_built:
        output.mkdir(parents=True)
        build(output, args.compiler.absolute(), env)
    check_combined(output, args.compiler.absolute(), env)
    exercise(output, env)
    exercise(output, env, rejection=True)
    exercise(output, env, claim=True)
    exercise(output, env, from_v2=True)
    exercise(output, env, epoch_tail=True)
    for boundary in ("row-catchup-after-step", "row-contract-after-retirement-statement", "row-contract-after-retirement"):
        exercise(output, env, crash=boundary)


if __name__ == "__main__":
    main()

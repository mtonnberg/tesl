#!/usr/bin/env python3
"""Catch a restored early-version backup up across a long revision gap.

Opt-in witness; not part of a CI gate. It builds one synthetic history with the
revision generator of scripts/measure-migration-scaling.py (the real compiler
preview flow: `migrate generate --new-revision`, `generate`, `contract`), but
with an application that can write rows. Only a few releases become executables:
the data version K and every requested gap end.

The K binary installs a fresh database, data is written at VK (rows through
HTTP, then bulk rows and optional-field values by an SQL observer) and the whole
database is dumped with `pg_dump` plus `pg_dumpall --globals-only`. For every gap
end G the dump is restored into a NEW PostgreSQL cluster and only the G binary
runs `--schema install`, `--schema catch-up` and its own Contract. Every
optional value written at VK must arrive under the field's final name at VG;
the G application serves the rows and a replayed catch-up changes nothing.

    python3 scripts/test-migration-long-gap.py --output .tesl-stuff/long-gap \\
        --revisions 120 --constant-schema --data-at 1 --gaps 30,60,120

Writes OUTPUT/long-gap.json with build and catch-up timings per gap.
"""
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
import urllib.request

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SCALING = runpy.run_path(str(HERE / "measure-migration-scaling.py"))
command, preview = SCALING["command"], SCALING["preview"]
ENTITIES = SCALING["ENTITIES"]

APPLICATION = '''module App exposing [Main]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Env exposing [env, envInt, envRead]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection, MigrationConfig, Worker]
import Tesl.App exposing [App]
import Tesl.Json exposing [stringCodec]
import Schema.Scale.VCurrent exposing [Alpha, Beta, Gamma, makeAlpha, makeBeta, makeGamma]
database Main = Database { schema: Schema.Scale.VCurrent, migrations: Schema.Scale.Migrate,
 backend: Postgres (PostgresConfig { namespace: "scale", dbName: env "S_DB", user: env "S_USER", password: "",
 connection: TcpConnection { host: env "S_HOST", port: envInt "S_PORT" 5432 },
 migrations: MigrationConfig { topology: Worker, controlOwner: env "S_OWNER", requestRole: env "S_REQUEST", workerRole: env "S_WORKER", ddlConnection: env "S_DDL" } }) }
record Reply { id: String, name: String }
codec Reply { toJson { id -> "id" with_codec stringCodec, name -> "name" with_codec stringCodec } fromJson_forbidden }
capturer idCapture: id: String using stringCodec
handler get health() -> String = "ready"
handler post createRows(id: String) -> String requires [dbWrite Alpha, dbWrite Beta, dbWrite Gamma] =
 let a = [makeAlpha id]
 let _ = insertMany a in Alpha
 let b = [makeBeta id]
 let _ = insertMany b in Beta
 let g = [makeGamma id]
 let _ = insertMany g in Gamma
 "seeded"
handler get alpha(id: String) -> Reply requires [dbRead Alpha] =
 case selectOne r from Alpha where r.id == id of
  Nothing -> fail 404 "missing"
  Something r -> Reply { id: r.id, name: r.name }
api ScaleApi {
get "/health" -> String
post "/seed/:id" capture id: String via idCapture -> String
get "/alpha/:id" capture id: String via idCapture -> Reply
}
server ScaleServer for ScaleApi { health, createRows, alpha, listenAddress Loopback }
main() -> App requires [dbRead Alpha, dbWrite Alpha, dbWrite Beta, dbWrite Gamma, envRead] =
App { database: Main, api: ScaleServer, port: envInt "S_HTTP_PORT" 8099 }
'''


def build(output, compiler, env, revisions, constant, keep):
    """Freeze [revisions] releases; emit and link executables for [keep]."""
    history, changes = SCALING["plan"](revisions, constant)
    source = output / "source"
    (source / "schema/scale").mkdir(parents=True)
    (source / "tesl.toml").write_text(SCALING["TOML"])
    entry, current = source / "app.tesl", source / "schema/scale/v-current.tesl"
    checked, timings = {}, []
    for version in range(1, revisions + 1):
        began = time.monotonic()
        if version > 1:
            preview(compiler, entry, env, "generate", "--new-revision", timeout=1200)
        current.write_text(SCALING["schema"](history[version]))
        if version == 1:
            entry.write_text(APPLICATION)
        else:
            edge = source / f"migrations/scale/v{version}.tesl"
            edge.write_text(edge.read_text().split("module ", 1)[0] + SCALING["migration"](version, history[version-1], history[version], changes[version]))
            preview(compiler, entry, env, "generate", timeout=1200)
            if changes[version][1] == "rename":
                preview(compiler, entry, env, "contract", "--version", str(version), timeout=1200)
        for file in sorted(source.rglob("*.tesl")):
            key, digest = str(file.relative_to(source)), hashlib.sha256(file.read_bytes()).hexdigest()
            if checked.get(key) != digest:
                context = json.loads(command([compiler, "agent-context", file], env=env, timeout=1200))
                if not context["ok"]:
                    raise RuntimeError(json.dumps(context, indent=2))
                checked[key] = digest
        record = {"version": version, "sourceSeconds": time.monotonic() - began}
        if version in keep:
            release = output / f"v{version}"
            shutil.copytree(source, release / "source")
            linked = time.monotonic()
            command([compiler, "--backend", "go", entry, "--out", release / "go"], env=env, timeout=1200)
            command(["go", "build", "-trimpath", "-o", release / "app", "./cmd/app"], cwd=release / "go", env=env, timeout=600)
            record["emitAndLinkSeconds"] = time.monotonic() - linked
        timings.append(record)
        print(f"Built V{version}: {record['sourceSeconds']:.2f}s" + (f" + executable {record['emitAndLinkSeconds']:.2f}s" if version in keep else ""), flush=True)
    return history, changes, timings


def final_names(changes, start, end):
    """Map each field present at V[start] to its name at V[end]."""
    names = {e: {} for e in ENTITIES}
    for version in range(start + 1, end + 1):
        entity, kind, old, new = changes[version]
        if kind == "rename":
            for origin, now in names[entity].items():
                if now == old:
                    names[entity][origin] = new
            names[entity].setdefault(old, new)
    return names


class Cluster:
    def __init__(self, env, home):
        self.env, self.home = env, home
        home.mkdir(parents=True)
        self.data = home / "postgres-data"
        self.sockets = Path(tempfile.mkdtemp(prefix="longgap-", dir="/tmp"))
        self.admin = dict(env, PGHOST=str(self.sockets), PGPORT="5432", PGUSER="s_installer", PGDATABASE="postgres")
        self.processes = []
        command(["initdb", "-D", self.data, "-U", "s_installer", "--auth=trust", "--no-locale", "--encoding=UTF8"])
        command(["pg_ctl", "-D", self.data, "-l", home / "postgres.log", "-o", f"-k {self.sockets} -h ''", "-w", "start"])

    def sql(self, query, database="scale"):
        return command(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atc", query], env=dict(self.admin, PGDATABASE=database)).strip()

    def appenv(self, role, port=0):
        return dict(self.env, S_HOST=str(self.sockets), S_PORT="5432", S_DB="scale", S_USER=role, S_OWNER="s_owner",
                    S_WORKER="s_worker", S_REQUEST="s_request", S_DDL=f"host={self.sockets} dbname=scale user={role}", S_HTTP_PORT=str(port))

    def schema(self, app, role, *args, timeout=3600):
        result = subprocess.run([str(app), "--schema", *args, "--json"], env=self.appenv(role), text=True, capture_output=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(f"{app} --schema {' '.join(args)}:\n{result.stdout}\n{result.stderr}")
        return result.stdout

    def serve(self, app, worker=False):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        log = open(self.home / f"{'worker' if worker else 'request'}-{len(self.processes)}.log", "w+")
        proc = subprocess.Popen([str(app)] + (["--schema", "worker", "--json"] if worker else []),
                                env=self.appenv("s_worker" if worker else "s_request", port), stdout=log, stderr=log)
        self.processes.append((proc, log))
        until = time.monotonic() + 120
        while time.monotonic() < until:
            if proc.poll() is not None:
                raise RuntimeError(f"{app} exited:\n{Path(log.name).read_text()}")
            try:
                if worker and "schema-worker-ready" in Path(log.name).read_text() or not worker and call(port, "GET", "/health") == "ready":
                    return proc, port
            except (OSError, ValueError):
                pass
            time.sleep(.1)
        raise RuntimeError(f"{app} not ready:\n{Path(log.name).read_text()}")

    def close(self):
        for proc, log in reversed(self.processes):
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=10)
            log.close()
        subprocess.run(["pg_ctl", "-D", str(self.data), "-m", "immediate", "-w", "stop"], capture_output=True)
        shutil.rmtree(self.data, ignore_errors=True)
        shutil.rmtree(self.sockets, ignore_errors=True)


def call(port, method, path):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method, data=b"" if method == "POST" else None)
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.loads(response.read())


def state(cluster):
    return cluster.sql("select current||','||min_version||','||compat_floor from scale.tesl_schema_state")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, default=ROOT / "compiler/_build/default/bin/main.exe")
    parser.add_argument("--revisions", type=int, default=120)
    parser.add_argument("--constant-schema", action="store_true", help="every release renames a field (all transforming)")
    parser.add_argument("--data-at", type=int, default=1, help="version whose database is backed up")
    parser.add_argument("--gaps", default="", help="comma-separated gap ends (default: the last revision)")
    parser.add_argument("--rows", type=int, default=1000, help="rows per entity written at the data version")
    args = parser.parse_args()
    gaps = sorted({int(g) for g in args.gaps.split(",") if g} or {args.revisions})
    if not (1 <= args.data_at < gaps[0] and gaps[-1] <= args.revisions):
        parser.error("need 1 <= --data-at < every gap end <= --revisions")
    output, compiler = args.output.resolve(), args.compiler.resolve()
    if output.exists():
        parser.error("use a new output directory")
    output.mkdir(parents=True)
    env = dict(os.environ, TESL_REPO_ROOT=str(ROOT))
    report = {"revisions": args.revisions, "constantSchema": args.constant_schema, "dataAt": args.data_at, "rows": args.rows, "gaps": []}
    began = time.monotonic()
    history, changes, timings = build(output, compiler, env, args.revisions, args.constant_schema, {args.data_at, *gaps})
    report["buildSeconds"], report["build"] = time.monotonic() - began, timings
    k = args.data_at
    origin = Cluster(env, output / "origin")
    try:
        origin.sql("create role s_owner nologin; create role s_worker login; create role s_request login", "postgres")
        origin.sql("create database scale", "postgres")
        origin.sql("grant create on database scale to s_owner", "postgres")
        origin.sql("grant create on schema public to s_owner")
        app = output / f"v{k}/app"
        origin.schema(app, "s_installer", "install", "--worker", "s_worker", "--request", "s_request")
        if k > 1:
            origin.schema(app, "s_worker", "catch-up")
            if changes[k][1] == "rename":
                origin.schema(app, "s_worker", "contract", f"V{k}")
            else:
                origin.schema(app, "s_worker", "close-epoch", "--through", f"V{k}", "--force")
        origin.serve(app, worker=True)
        assert state(origin) == f"{k},{k},{k}", state(origin)
        _, port = origin.serve(app)
        for index in range(3):
            assert call(port, "POST", f"/seed/http-{index}") == "seeded"
        values = {}
        for entity in ENTITIES:
            table = entity.lower() + "s"
            optional = [f for f, t in history[k][entity].items() if t == "Maybe String"]
            columns = ", ".join(["id", "name"] + optional)
            exprs = ", ".join(["'bulk-'||i", "'n'"] + [f"'{f}-bulk-'||i" for f in optional])
            origin.sql(f"insert into scale.{table} ({columns}) select {exprs} from generate_series(1, {args.rows}) i")
            if optional:
                origin.sql(f"update scale.{table} set " + ", ".join(f"{f} = '{f}-'||id" for f in optional) + " where id like 'http-%'")
            values[entity] = optional
        identity = origin.sql("select database_uuid::text from scale.tesl_schema_meta")
        dump = output / "origin/scale.dump"
        command(["pg_dump", "--format=custom", "--file", dump, "scale"], env=dict(origin.admin, PGDATABASE="scale"))
        command(["pg_dumpall", "--globals-only", "--file", output / "origin/globals.sql"], env=origin.admin)
        report["dumpBytes"] = dump.stat().st_size
    finally:
        origin.close()
    roles = (output / "origin/globals.sql").read_text()
    assert "CREATE ROLE s_installer;\n" in roles
    (output / "origin/roles.sql").write_text(roles.replace("CREATE ROLE s_installer;\n", ""))
    quiet_since = time.monotonic()
    for gap in gaps:
        cluster = Cluster(env, output / f"restore-v{gap}")
        try:
            command(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-q", "-f", output / "origin/roles.sql"], env=cluster.admin)
            command(["pg_restore", "--create", "--exit-on-error", "--dbname", "postgres", dump], env=cluster.admin)
            assert state(cluster) == f"{k},{k},{k}"
            app = output / f"v{gap}/app"
            cluster.schema(app, "s_installer", "install", "--worker", "s_worker", "--request", "s_request")
            if time.monotonic() - quiet_since < 31:
                time.sleep(31 - (time.monotonic() - quiet_since))
            started = time.monotonic()
            caught = json.loads(cluster.schema(app, "s_worker", "catch-up"))
            catch_up = time.monotonic() - started
            assert caught["kind"] == "schema-caught-up" and caught["currentVersion"] == gap, caught
            started = time.monotonic()
            if changes[gap][1] == "rename":
                cluster.schema(app, "s_worker", "contract", f"V{gap}")
            else:
                cluster.schema(app, "s_worker", "close-epoch", "--through", f"V{gap}", "--force")
            finish = time.monotonic() - started
            assert state(cluster) == f"{gap},{gap},{gap}", state(cluster)
            assert cluster.sql("select database_uuid::text from scale.tesl_schema_meta") == identity
            receipts = cluster.sql("select md5(json_agg(v order by version, step)::text) from scale.tesl_schema_versions v")
            again = json.loads(cluster.schema(app, "s_worker", "catch-up"))
            assert again["currentVersion"] == gap and receipts == cluster.sql("select md5(json_agg(v order by version, step)::text) from scale.tesl_schema_versions v")
            names = final_names(changes, k, gap)
            for entity in ENTITIES:
                table = entity.lower() + "s"
                assert int(cluster.sql(f"select count(*) from scale.{table}")) == args.rows + 3
                for field in values[entity]:
                    now = names[entity].get(field, field)
                    wrong = cluster.sql(f"select count(*) from scale.{table} where {now} is distinct from '{field}-'||id")
                    assert wrong == "0", (gap, entity, field, now, wrong)
            cluster.serve(app, worker=True)
            _, port = cluster.serve(app)
            assert call(port, "GET", "/alpha/http-1") == {"id": "http-1", "name": "n"}
            assert call(port, "GET", "/alpha/bulk-7") == {"id": "bulk-7", "name": "n"}
            assert call(port, "POST", "/seed/after-catch-up") == "seeded"
            transforming = sum(1 for v in range(k + 1, gap + 1) if changes[v][1] == "rename")
            record = {"from": k, "to": gap, "revisions": gap - k, "transformingRevisions": transforming,
                      "catchUpSeconds": catch_up, "finalitySeconds": finish}
            report["gaps"].append(record)
            print(f"PASS V{k} backup -> V{gap}: {gap-k} revisions ({transforming} transforming), catch-up {catch_up:.2f}s, "
                  f"final Contract/closure {finish:.2f}s, {args.rows + 3} rows per entity verified", flush=True)
        finally:
            cluster.close()
        (output / "long-gap.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: long-gap restore + catch-up from V{k} across {len(gaps)} gap(s)", flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Measure per-release compiler time as a migration history grows.

Opt-in benchmark; not part of any CI gate. It builds one synthetic project with
N revisions through the real compiler-owned preview flow (`tesl migrate generate
--new-revision`, `generate`, `contract`, the same steps
example/db-twenty-releases/run.py uses) and records, for every release, the time
spent in the compiler: the previews, `agent-context` on every changed source and
one Go emit. It never runs `go build` or PostgreSQL.

Each release changes one of three entities, cycling: most releases add an
optional field; every fifth release renames an earlier optional field (a
transforming step with a converter and a Contract).

    python3 scripts/measure-migration-scaling.py --output .tesl-stuff/scaling --revisions 60

Writes OUTPUT/scaling.json and prints one line per release. Compare runs with
`--full-history` to see the cost of re-checking every frozen revision.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
COMMON = runpy.run_path(str(ROOT / "example/db-three-upgrades/run.py"))
command, preview = COMMON["command"], COMMON["apply_preview"]
ENTITIES = ["Alpha", "Beta", "Gamma"]
TOML = "# Synthetic scaling project; releases are frozen through compiler previews.\n"


def plan(revisions, constant=False):
    """Return (fields per version, change per version).

    With [constant], every entity starts with three optional fields and every
    release renames one of them, so the schema keeps its size and only the
    history grows."""
    state = {e: {"id": "String", "name": "String"} for e in ENTITIES}
    if constant:
        for e in ENTITIES:
            state[e].update({f"f{i}": "Maybe String" for i in range(1, 4)})
    history, changes = {1: {e: dict(f) for e, f in state.items()}}, {1: None}
    for version in range(2, revisions + 1):
        entity = ENTITIES[version % 3]
        optional = [k for k, t in state[entity].items() if t == "Maybe String"]
        if (constant or version % 5 == 0) and optional:
            old = optional[0]
            new = f"{old.split('r')[0]}r{version}"
            state[entity] = {(new if k == old else k): t for k, t in state[entity].items()}
            changes[version] = (entity, "rename", old, new)
        else:
            state[entity][f"o{version}"] = "Maybe String"
            changes[version] = (entity, "add", f"o{version}", None)
        history[version] = {e: dict(f) for e, f in state.items()}
    return history, changes


def schema(fields):
    exports = ENTITIES + ["make" + e for e in ENTITIES]
    lines = ["module Schema.Scale.VCurrent exposing [" + ", ".join(exports) + "]",
             "import Tesl.Prelude exposing [String]", "import Tesl.Maybe exposing [Maybe(..)]"]
    for entity in ENTITIES:
        members = fields[entity]
        lines.append(f'entity {entity} table "{entity.lower()}s" primaryKey id {{ '
                     + ", ".join(f"{k}: {t}" for k, t in members.items()) + " }")
        values = {k: ("id" if k == "id" else '"n"' if t == "String" else "Nothing") for k, t in members.items()}
        lines.append(f"fn make{entity}(id: String) -> {entity} = {entity} {{ "
                     + ", ".join(f"{k}: {v}" for k, v in values.items()) + " }")
    return "\n".join(lines) + "\n"


def migration(version, before, after, change):
    previous, current = f"Schema.Scale.V{version-1}", "Schema.Scale.VCurrent"
    entity, kind, old, new = change
    decisions, functions, fixtures = [], [], []
    if kind == "add":
        decisions.append(f"{entity}: Additive []")
    else:
        decisions.append(f"{entity}: Migrate convert{entity} [Rename {old} {new}]")
        values = {k: f"old.{old if k == new else k}" for k in after[entity]}
        functions += [f"fn convert{entity}(old: {previous}.{entity}) -> Migrated {current}.{entity} =",
                      f"  Row ({current}.{entity} {{ " + ", ".join(f"{k}: {v}" for k, v in values.items()) + " })",
                      f"fn fixture{entity}() -> {previous}.{entity} = {previous}.make{entity} \"fixture\""]
        fixtures.append("fixture" + entity)
    return f'''module Schema.Scale.Migrate.V{version} exposing [migration]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import {previous}
import {current}
migration = Migration {{
 from: {previous}
 to: {current}
 same: []
 entities: {{ {", ".join(decisions)} }}
 fixtures: [{", ".join(fixtures)}]
}}
''' + "\n".join(functions) + "\n"


APPLICATION = '''module App exposing [Main]
import Tesl.Prelude exposing [String]
import Tesl.Env exposing [env, envInt, envRead]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection, MigrationConfig, Worker]
import Tesl.App exposing [App]
import Schema.Scale.VCurrent exposing [Alpha]
database Main = Database { schema: Schema.Scale.VCurrent, migrations: Schema.Scale.Migrate,
 backend: Postgres (PostgresConfig { namespace: "scale", dbName: env "S_DB", user: env "S_USER", password: "",
 connection: TcpConnection { host: env "S_HOST", port: envInt "S_PORT" 5432 },
 migrations: MigrationConfig { topology: Worker, controlOwner: env "S_OWNER", requestRole: env "S_REQUEST", workerRole: env "S_WORKER", ddlConnection: env "S_DDL" } }) }
api ScaleApi {
get "/health" -> String
}
handler get health() -> String = "ready"
server ScaleServer for ScaleApi { health }
main() -> App requires [envRead] =
App { database: Main, api: ScaleServer, port: envInt "S_HTTP_PORT" 8099 }
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, default=ROOT / "compiler/_build/default/bin/main.exe")
    parser.add_argument("--revisions", type=int, default=60)
    parser.add_argument("--full-history", action="store_true", help="set TESL_FULL_HISTORY=1 for every command")
    parser.add_argument("--constant-schema", action="store_true",
                        help="rename a field every release instead of growing the schema")
    parser.add_argument("--no-emit", action="store_true", help="skip the per-release Go emit")
    parser.add_argument("--keep", default="", help="comma-separated releases whose sources are copied to OUTPUT/snapshots/vN")
    args = parser.parse_args()
    if args.revisions < 2:
        parser.error("--revisions must be at least 2")
    output, compiler = args.output.resolve(), args.compiler.resolve()
    if output.exists():
        parser.error("use a new output directory")
    source = output / "source"
    (source / "schema/scale").mkdir(parents=True)
    (source / "tesl.toml").write_text(TOML)
    env = dict(os.environ, TESL_REPO_ROOT=str(ROOT))
    if args.full_history:
        env["TESL_FULL_HISTORY"] = "1"
    entry, current = source / "app.tesl", source / "schema/scale/v-current.tesl"
    history, changes = plan(args.revisions, args.constant_schema)
    checked, records = {}, []
    for version in range(1, args.revisions + 1):
        seconds = {}

        def timed(name, run):
            began = time.monotonic()
            result = run()
            seconds[name] = seconds.get(name, 0.0) + time.monotonic() - began
            return result
        if version > 1:
            timed("newRevision", lambda: preview(compiler, entry, env, "generate", "--new-revision", timeout=600))
        current.write_text(schema(history[version]))
        if version == 1:
            entry.write_text(APPLICATION)
        else:
            edge = source / f"migrations/scale/v{version}.tesl"
            header = edge.read_text().split("module ", 1)[0]
            edge.write_text(header + migration(version, history[version-1], history[version], changes[version]))
            timed("generate", lambda: preview(compiler, entry, env, "generate", timeout=600))
            if changes[version][1] == "rename":
                timed("contract", lambda: preview(compiler, entry, env, "contract", "--version", str(version), timeout=600))
        for file in sorted(source.rglob("*.tesl")):
            key, digest = str(file.relative_to(source)), hashlib.sha256(file.read_bytes()).hexdigest()
            if checked.get(key) == digest:
                continue
            context = json.loads(timed("agentContext", lambda: command([compiler, "agent-context", file], env=env, timeout=600)))
            if not context["ok"]:
                raise RuntimeError(json.dumps(context, indent=2))
            checked[key] = digest
        if not args.no_emit:
            out = output / "go"
            shutil.rmtree(out, ignore_errors=True)
            timed("emit", lambda: command([compiler, "--backend", "go", entry, "--out", out], env=env, timeout=600))
        if str(version) in args.keep.split(","):
            shutil.copytree(source, output / "snapshots" / f"v{version}")
        record = {"version": version, "change": changes[version], "seconds": seconds, "total": sum(seconds.values())}
        records.append(record)
        (output / "scaling.json").write_text(json.dumps({"fullHistory": args.full_history, "releases": records}, indent=2) + "\n")
        parts = " ".join(f"{k}={v:.2f}" for k, v in seconds.items())
        print(f"V{version}: {record['total']:.2f}s {parts}", flush=True)


if __name__ == "__main__":
    main()

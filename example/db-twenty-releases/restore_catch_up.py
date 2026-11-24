#!/usr/bin/env python3
"""Restore an older backup into a new PostgreSQL cluster and catch it up with the newest release.

The sequential twenty-release deployment (run.py) is the source of real data. At
each requested version it takes a whole-database `pg_dump` (plus the cluster's
roles from `pg_dumpall --globals-only`) while that version's processes still run.
After the source cluster stops, each dump is restored into a NEW cluster, where
only the newest binary migrates it: `--schema install` as Installer, then
`--schema catch-up` as Worker and the newest Contract, as
manual/migration-operations.md prescribes. Before that, an older binary must
refuse a finalized backup, and catch-up must refuse while the restored version
still has a recent heartbeat. The newest application then serves every restored
cohort with its transformed values and runs its API tests against the restored
data; replaying the commands changes nothing.

A backup point is `N` (after VN's finality) or `Nopen` (VN expanded while the
predecessor binary is still admitted, before retirement). Without --backups the
script deploys V1..max(N) itself; with --backups it restores the dumps that
`run.py --backup-at` kept during an ordinary twenty-release run.

    python3 example/db-twenty-releases/run.py --output .tesl-stuff/tracker20 --build-only
    python3 example/db-twenty-releases/restore_catch_up.py --artifacts .tesl-stuff/tracker20 \\
        --evidence .tesl-stuff/tracker20-restore --from 1,5,6,7open,13,19

    python3 example/db-twenty-releases/run.py --output .tesl-stuff/tracker20 --run-built \\
        --evidence .tesl-stuff/tracker20-run --backup-at 1,7open,13
    python3 example/db-twenty-releases/restore_catch_up.py --artifacts .tesl-stuff/tracker20 \\
        --evidence .tesl-stuff/tracker20-restore --backups .tesl-stuff/tracker20-run/backups
"""
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
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RUN = runpy.run_path(str(HERE / "run.py"))
command, optional_values, backup_database, parse_points = RUN["command"], RUN["optional_values"], RUN["backup_database"], RUN["parse_backup_points"]
LATEST = 20


def request(port, method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.loads(response.read())


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def stop(proc):
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=10)


class Restored:
    """A private cluster holding one restored backup."""

    def __init__(self, artifacts, env, case):
        self.artifacts, self.env, self.case = artifacts, env, case
        self.data = case / "postgres-data"
        self.sockets = Path(tempfile.mkdtemp(prefix="restore20-", dir="/tmp"))
        self.admin = dict(env, PGHOST=str(self.sockets), PGPORT="5432", PGUSER="lived_installer", PGDATABASE="postgres")
        self.processes = []

    def sql(self, query, database="tracker20"):
        return command(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atc", query], env=dict(self.admin, PGDATABASE=database)).strip()

    def state(self):
        return self.sql("select row_to_json(s)::text from tracker.tesl_schema_state s")

    def receipts(self):
        return self.sql("select json_agg(v order by version, step)::text from tracker.tesl_schema_versions v")

    def appenv(self, role, port=0):
        return dict(self.env, LIVED_HOST=str(self.sockets), LIVED_PORT="5432", LIVED_DB="tracker20", LIVED_USER=role,
                    LIVED_OWNER="lived_owner", LIVED_WORKER="lived_worker", LIVED_REQUEST="lived_request",
                    LIVED_DDL=f"host={self.sockets} dbname=tracker20 user={role}", LIVED_HTTP_PORT=str(port))

    def schema(self, version, role, *args, ok=True, timeout=120):
        result = subprocess.run([str(self.artifacts / f"v{version}/app"), "--schema", *args, "--json"],
                                env=self.appenv(role), text=True, capture_output=True, timeout=timeout)
        if ok and result.returncode:
            raise RuntimeError(f"V{version} {' '.join(args)}:\n{result.stdout}\n{result.stderr}")
        return result

    def start(self, version, worker=False, expect_ready=True, timeout=45):
        port = free_port()
        log = open(self.case / f"v{version}-{'worker' if worker else 'request'}-{len(self.processes)}.log", "w+")
        args = [str(self.artifacts / f"v{version}/app")] + (["--schema", "worker", "--json"] if worker else [])
        proc = subprocess.Popen(args, env=self.appenv("lived_worker" if worker else "lived_request", port), stdout=log, stderr=log)
        self.processes.append((proc, log))
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            if proc.poll() is not None:
                if expect_ready:
                    raise RuntimeError(f"V{version} exited {proc.returncode}:\n{Path(log.name).read_text()}")
                return proc, port, Path(log.name).read_text()
            try:
                if worker and "schema-worker-ready" in Path(log.name).read_text() or not worker and request(port, "GET", "/health") == f"ready-v{version}":
                    if not expect_ready:
                        raise RuntimeError(f"V{version} unexpectedly served the restored database")
                    return proc, port, None
            except (OSError, ValueError):
                pass
            time.sleep(.1)
        if expect_ready:
            raise RuntimeError(f"V{version} did not become ready:\n{Path(log.name).read_text()}")
        stop(proc)
        return proc, port, Path(log.name).read_text()

    def close(self):
        for proc, log in reversed(self.processes):
            stop(proc)
            log.close()
        subprocess.run(["pg_ctl", "-D", str(self.data), "-m", "immediate", "-w", "stop"], capture_output=True)
        shutil.rmtree(self.data, ignore_errors=True)
        shutil.rmtree(self.sockets, ignore_errors=True)


def verify(cluster, port, through, enriched, expected):
    """Every restored cohort reads back through V20's HTTP API with V20's transformed values."""
    # From V7 on, the seed task's last edit before the backup came from a V7+
    # binary, which writes the new metadata kind itself.
    seed = request(port, "GET", "/tasks/seed-task")
    flavor = "migrated-v7" if through < 7 else "created"
    assert seed["title"] == "Seed task" and seed["content"] == expected and seed["flavor"] == flavor and seed["revision"] == 13, seed
    assert request(port, "GET", "/projects/seed-project") == {"id": "seed-project", "name": "Original project"}
    assert request(port, "GET", "/members/seed-member") == {"id": "seed-member", "name": "Original member"}
    for born in range(1, through + 1):
        assert request(port, "GET", f"/projects/api-v{born}") == {"id": f"api-v{born}", "name": f"Project v{born}"}
        assert request(port, "GET", f"/members/api-v{born}") == {"id": f"api-v{born}", "name": f"Member v{born}"}
        task = request(port, "GET", f"/tasks/api-v{born}")
        flavor = "migrated-v7" if born < 7 else "created"
        assert task == {"id": f"api-v{born}", "projectId": f"api-v{born}", "title": f"Updated v{born}", "content": f"updated-v{born}", "flavor": flavor, "revision": 13}, task
        if born >= 6:
            assert request(port, "GET", f"/audits/api-v{born}") == {"id": f"api-v{born}", "name": f"Audit v{born}"}
        # Optional fields seeded by the SQL observer before the backup survive
        # every later rename/retype; cohorts never enriched stay empty.
        for table, values in optional_values(born, LATEST).items():
            if not values or table == "audits" and born < 6:
                continue
            row = json.loads(cluster.sql(f"select row_to_json(t) from tracker.{table} t where id='api-v{born}'"))
            for field, value in values.items():
                want = value if born <= enriched else None
                assert row[field] == want, (born, table, field, row[field], want)
    counts = {table: int(cluster.sql(f"select count(*) from tracker.{table}")) for table in ("projects", "tasks", "members", "audits")}
    assert counts == {"projects": through + 1, "tasks": through + 1, "members": through + 1, "audits": through - 4 if through >= 6 else 0}, counts


def restore_case(artifacts, env, backup):
    phase, version, case, source_state = backup["phase"], backup["version"], backup["case"], backup["state"]
    record = {"backup": f"V{version}" + (" (open window)" if phase == "open" else " (final)"),
              "dumpBytes": (case / "tracker20.dump").stat().st_size}
    began = time.monotonic()
    cluster = Restored(artifacts, env, case)
    try:
        command(["initdb", "-D", cluster.data, "-U", "lived_installer", "--auth=trust", "--no-locale", "--encoding=UTF8"])
        command(["pg_ctl", "-D", cluster.data, "-l", case / "postgres.log", "-o", f"-k {cluster.sockets} -h '' -c max_connections=40", "-w", "start"])
        # The bootstrap superuser already exists in the new cluster; every
        # other role statement must apply.
        roles = (case / "globals.sql").read_text()
        assert "CREATE ROLE lived_installer;\n" in roles
        (case / "roles.sql").write_text(roles.replace("CREATE ROLE lived_installer;\n", ""))
        command(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-q", "-f", case / "roles.sql"], env=cluster.admin)
        command(["pg_restore", "--create", "--exit-on-error", "--dbname", "postgres", case / "tracker20.dump"], env=cluster.admin)
        record["restoreSeconds"] = time.monotonic() - began
        assert cluster.sql("select database_uuid::text from tracker.tesl_schema_meta") == backup["identity"]
        assert cluster.state() == source_state, (cluster.state(), source_state)
        assert cluster.sql("select count(*) > 0 from public.tesl_fence_namespaces") == "t"

        # Refusals before any catch-up. A binary older than the restored
        # admission floor refuses; in an open-window backup the predecessor is
        # still admitted, as the operator guide states.
        if version > 1:
            older = version - 1
            proc, _, log = cluster.start(older, expect_ready=phase == "open", timeout=45 if phase == "open" else 15)
            if phase == "open":
                stop(proc)
                record["olderBinary"] = f"V{older} served (still admitted)"
            else:
                assert proc.returncode not in (None, 0, -15), log
                record["olderBinary"] = f"V{older} exited {proc.returncode}: " + (log.strip().splitlines()[0] if log.strip() else "")
            assert cluster.state() == source_state
        # The newest Request binary cannot serve a database behind its expansion.
        proc, _, log = cluster.start(LATEST, expect_ready=False, timeout=8)
        record["latestBeforeCatchUp"] = (f"exited {proc.returncode}: " + (log.strip().splitlines()[-1] if log.strip() else "")) if proc.returncode != -15 else "waited without serving"
        assert cluster.state() == source_state

        install = cluster.schema(LATEST, "lived_installer", "install", "--worker", "lived_worker", "--request", "lived_request")
        record["install"] = install.stdout.strip().splitlines()[-1] if install.stdout.strip() else ""
        installed_state = cluster.state()
        # The backed-up version still serves the restored copy. Catch-up must
        # retire every version below V20's predecessor; while such a version
        # has a recent heartbeat it refuses without changing anything. V19 is
        # V20's admitted predecessor, so a V19 backup catches up while V19 runs.
        proc, _, _ = cluster.start(version)
        if json.loads(source_state)["min_version"] < LATEST - 1:
            refused = cluster.schema(LATEST, "lived_worker", "catch-up", ok=False)
            assert refused.returncode != 0 and "stop those" in refused.stderr, refused
            record["recentInstanceRefusal"] = refused.stderr.strip().splitlines()[-1]
            stop(proc)
            assert cluster.state() == installed_state
            time.sleep(31)
        began = time.monotonic()
        caught_up = json.loads(cluster.schema(LATEST, "lived_worker", "catch-up", timeout=600).stdout)
        record["catchUpSeconds"] = time.monotonic() - began
        assert caught_up["kind"] == "schema-caught-up" and caught_up["currentVersion"] == caught_up["binaryVersion"] == LATEST, caught_up
        stop(proc)
        began = time.monotonic()
        cluster.schema(LATEST, "lived_worker", "contract", f"V{LATEST}")
        record["contractSeconds"] = time.monotonic() - began
        assert cluster.sql("select current||','||min_version||','||compat_floor from tracker.tesl_schema_state") == f"{LATEST},{LATEST},{LATEST}"
        assert cluster.sql("select database_uuid::text from tracker.tesl_schema_meta") == backup["identity"]

        # Replays change nothing: the same commands on the caught-up database.
        settled, receipts = cluster.state(), cluster.receipts()
        cluster.schema(LATEST, "lived_installer", "install", "--worker", "lived_worker", "--request", "lived_request")
        again = json.loads(cluster.schema(LATEST, "lived_worker", "catch-up").stdout)
        assert again["kind"] == "schema-caught-up" and again["currentVersion"] == LATEST, again
        cluster.schema(LATEST, "lived_worker", "contract", f"V{LATEST}")
        assert (cluster.state(), cluster.receipts()) == (settled, receipts)

        cluster.start(LATEST, worker=True)
        _, port, _ = cluster.start(LATEST)
        enriched = version if phase == "final" else version - 1
        verify(cluster, port, version, enriched, backup["expected"])
        if version < 6:
            request(port, "POST", "/audits/seed-audit", {"name": "Original audit"})
        api_env = dict(cluster.appenv("lived_request"), LIVED_API_DATABASE="1", LIVED_EXPECT_CONTENT=backup["expected"])
        tests = command([artifacts / f"v{LATEST}/api.test", "-test.run", "^TestTeslApi", "-test.v", "-test.timeout=60s"], env=api_env, timeout=90)
        (case / "api-postgres.log").write_text(tests)
        if "postgres-api-tests: retained database bound" not in tests or tests.count("--- PASS: TestTeslApi") != 5 or "--- SKIP:" in tests:
            raise RuntimeError(f"V{LATEST} API suite did not execute all 5 PostgreSQL cases on the restored database:\n{tests}")
        record["apiTests"] = 5
        (case / "result.json").write_text(json.dumps(record, indent=2) + "\n")
        print(f"PASS restore {record['backup']}: V{LATEST} install + catch-up {record['catchUpSeconds']:.2f}s + Contract, "
              f"{version} cohorts, 5 API tests, replay unchanged", flush=True)
        return record
    finally:
        cluster.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--artifacts", type=Path, required=True, help="output of run.py with all twenty releases built")
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--from", dest="points", help="backup points: N or Nopen, 1-19 (default 1,5,6,7open,13,19, or every kept backup with --backups)")
    parser.add_argument("--backups", type=Path, help="restore backups kept by an earlier run (run.py --backup-at writes EVIDENCE/backups) instead of deploying again")
    args = parser.parse_args()
    kept = {}
    if args.backups:
        for path in sorted(args.backups.resolve().glob("from-v*/backup.json")):
            item = json.loads(path.read_text())
            kept[(item["phase"], item["version"])] = path.parent
        if not kept:
            parser.error(f"{args.backups} holds no from-v*/backup.json")
    try:
        points = parse_points(args.points) if args.points else set(kept) or parse_points("1,5,6,7open,13,19")
    except ValueError as error:
        parser.error(str(error))
    if args.backups and not points <= set(kept):
        parser.error(f"{args.backups} lacks backups for {sorted(points - set(kept))}")
    artifacts, evidence = args.artifacts.resolve(), args.evidence.resolve()
    if not (artifacts / f"v{LATEST}/build.json").exists():
        parser.error(f"{artifacts} lacks a complete V{LATEST} build")
    if evidence.exists():
        parser.error("use a new evidence directory")
    for tool in ("initdb", "pg_ctl", "psql", "pg_dump", "pg_dumpall", "pg_restore"):
        if not shutil.which(tool):
            parser.error(f"{tool} is required; run inside nix develop")
    env = dict(os.environ, TESL_REPO_ROOT=str(ROOT))
    backups, results = [], []

    def backup(phase, version, live):
        if (phase, version) in points:
            backups.append(backup_database(evidence, phase, version, live))
    if args.backups:
        for point in points:
            case = evidence / kept[point].name
            shutil.copytree(kept[point], case, ignore=lambda _, names: [n for n in names if n not in ("backup.json", "globals.sql", "tracker20.dump")])
            backups.append(dict(json.loads((case / "backup.json").read_text()), case=case))
        backups.sort(key=lambda item: (item["version"], item["phase"] == "final"))
    else:
        RUN["exercise"](artifacts, env, max(v for _, v in points), evidence / "source", backup=backup)
    assert len(backups) == len(points), backups
    for item in backups:
        results.append(restore_case(artifacts, env, item))
        (evidence / "restore.json").write_text(json.dumps(results, indent=2) + "\n")
    print(f"PASS: {len(results)} backups restored into new clusters and caught up by V{LATEST} alone", flush=True)


if __name__ == "__main__":
    main()

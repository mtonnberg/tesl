#!/usr/bin/env python3
"""Adversarial review 05: actual compiler and frozen public PostgreSQL binaries.

Run inside nix develop. --build creates reviewed release inputs from both runnable
examples; otherwise --artifacts must contain queue/ and row/ release directories.
Each database case clones an idle template, so attacks never contaminate another
case. The privileged observer injects faults; the operation under test still runs
under its documented application role. Logs and a JSON inventory are retained.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
import runpy
import threading

ROOT = Path(__file__).resolve().parents[1]
CONFIG = None


def run(args, *, env=None, cwd=None, timeout=90):
    return subprocess.run([str(x) for x in args], env=env, cwd=cwd, text=True,
                          capture_output=True, timeout=timeout)


def require(result):
    if result.returncode:
        raise RuntimeError(f"{result.args}:\n{result.stdout}\n{result.stderr}")
    return result.stdout.strip()


def literal(value):
    return "'" + value.replace("'", "''") + "'"


class Lab:
    def __init__(self):
        self.cluster = Path(tempfile.mkdtemp(prefix="review05-", dir="/tmp"))
        self.env = dict(os.environ, TESL_REPO_ROOT=str(ROOT))
        self.count = 0

    def sql(self, db, query, role="review_installer", ok=True):
        result = run(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atc", query],
                     env=dict(self.env, PGHOST=str(self.cluster), PGPORT="5432", PGDATABASE=db, PGUSER=role))
        return require(result) if ok else result

    def appenv(self, db, role):
        return dict(self.env, DEMO_DB=db, DEMO_HOST=str(self.cluster), DEMO_PORT="5432",
                    DEMO_OWNER="review_owner", DEMO_WORKER="review_worker", DEMO_REQUEST="review_request",
                    DEMO_USER=role, DEMO_DDL=f"host={self.cluster} dbname={db} user={role}", DEMO_HTTP_PORT="8099")

    def schema(self, db, release, *args, role="review_worker", family="queue"):
        return run([CONFIG.artifacts / family / release / "app", "--schema", *args, "--json"],
                   env=self.appenv(db, role), timeout=45)

    def install(self, db, release, family="queue"):
        return self.schema(db, release, "install", "--worker", "review_worker", "--request", "review_request",
                           role="review_installer", family=family)

    def start(self, db, release, family="queue"):
        log = open(CONFIG.output / f"{db}-{release}-worker.log", "w+")
        process = subprocess.Popen([str(CONFIG.artifacts / family / release / "app"), "--schema", "worker", "--json"],
                                   env=self.appenv(db, "review_worker"), stdout=log, stderr=log)
        try:
            self.wait(lambda: "schema-worker-ready" in Path(log.name).read_text(), process=process)
        except BaseException:
            self.stop(process, log)
            raise
        return process, log

    @staticmethod
    def stop(process, log):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=8)
        log.close()

    @staticmethod
    def wait(predicate, process=None, timeout=25):
        until = time.monotonic() + timeout
        while time.monotonic() < until:
            if predicate():
                return
            if process and process.poll() is not None:
                raise AssertionError(f"worker exited {process.returncode}")
            time.sleep(.05)
        raise AssertionError("bounded progress deadline expired")

    def prepare(self):
        require(run(["initdb", "-D", self.cluster / "data", "-U", "review_installer", "--auth=trust", "--no-locale", "--encoding=UTF8"]))
        require(run(["pg_ctl", "-D", self.cluster / "data", "-l", self.cluster / "postgres.log", "-o", f"-k {self.cluster} -h ''", "-w", "start"]))
        self.sql("postgres", "create role review_owner nologin; create role review_worker login; create role review_request login")
        self.sql("postgres", "create database review_v1")
        self.sql("postgres", "grant create on database review_v1 to review_owner")
        self.sql("review_v1", "grant create on schema public to review_owner")
        require(self.install("review_v1", "v1"))
        self.stop(*self.start("review_v1", "v1"))
        self.sql("postgres", "create database review_v2 template review_v1")
        require(self.install("review_v2", "v2"))
        self.stop(*self.start("review_v2", "v2"))
        self.sql("postgres", "create database review_retired template review_v2")
        require(self.install("review_retired", "v2-repair"))
        require(self.schema("review_retired", "v2-repair", "contract", "V2"))

    def clone(self, template="review_v2"):
        self.count += 1
        db = f"review_case_{self.count}"
        self.sql("postgres", f"create database {db} template {template}")
        return db

    def build_mixed_payloads(self):
        """A second, unchanged job type next to Delivery; public source only."""
        source = CONFIG.artifacts / "mixed/source"
        shutil.copytree(CONFIG.artifacts / "queue/v1/source", source)
        extra = '''
record Unchanged { text: String }
codec Unchanged {
  toJson { text -> "text" with_codec stringCodec }
  fromJson [ { text <- "text" with_codec stringCodec } ]
}
'''
        def schema(text):
            return text.replace("exposing [Delivery, Jobs]", "exposing [Delivery, Jobs, Unchanged]").replace("jobs: [Delivery]", "jobs: [Delivery, Unchanged]") + extra
        current = source / "schema/mail/v-current.tesl"
        current.write_text(schema(current.read_text()))
        entry = source / "app.tesl"
        entry.write_text(entry.read_text().replace("jobs: [Job Schema.Mail.VCurrent.Delivery handle Nothing]", "jobs: [Job Schema.Mail.VCurrent.Delivery handle Nothing, Job Schema.Mail.VCurrent.Unchanged unchanged Nothing]") + '\nworker unchanged(job: Schema.Mail.VCurrent.Unchanged ::: FromQueue (Id == jobId) job) = job\n')
        def emit(version):
            target = CONFIG.artifacts / f"mixed/v{version}"
            for file in source.rglob("*.tesl"):
                require(run([CONFIG.compiler, "agent-context", file], env=self.env))
            require(run([CONFIG.compiler, "--backend", "go", entry, "--out", target / "go"], env=self.env))
            require(run(["go", "build", "-race", "-o", target / "app", "./cmd/app"], cwd=target / "go", env=self.env))
        emit(1)
        preview = runpy.run_path(str(ROOT / "example/db-three-upgrades/run.py"))["apply_preview"]
        preview(CONFIG.compiler, entry, self.env, "generate", "--new-revision")
        current.write_text(schema((CONFIG.artifacts / "queue/v2/source/schema/mail/v-current.tesl").read_text()))
        helpers = source / "migrations/mail/convert2.tesl"
        shutil.copyfile(CONFIG.artifacts / "queue/v2/source/migrations/mail/convert2.tesl", helpers)
        edge = source / "migrations/mail/v2.tesl"
        body = (CONFIG.artifacts / "queue/v2/source/migrations/mail/v2.tesl").read_text().split("module ", 1)[1]
        edge.write_text(edge.read_text().split("module ", 1)[0] + "module " + body)
        preview(CONFIG.compiler, entry, self.env, "generate")
        emit(2)

    def close(self):
        run(["pg_ctl", "-D", self.cluster / "data", "-m", "immediate", "-w", "stop"])
        shutil.rmtree(self.cluster)

    def build_fairness_payloads(self, family="fair", extra_types=1):
        """Independently changed nominal job types, emitted as ordinary applications."""
        names = ["Other"] if extra_types == 1 else [f"Other{n:03}" for n in range(extra_types)]
        target_family = CONFIG.artifacts / family
        target_family.mkdir(exist_ok=True)
        # Preserve interrupted inputs; a retry starts in a fresh generated tree.
        source = Path(tempfile.mkdtemp(prefix="source-", dir=target_family))
        shutil.copytree(CONFIG.artifacts / "queue/v1/source", source, dirs_exist_ok=True)
        build_timeout = 600 if extra_types > 1 else 90
        def add_other(text, version):
            fields = 'text: String' if version == 1 else 'body: String, priority: Int'
            codec = 'text -> "oldText" with_codec stringCodec' if version == 1 else 'body -> "message" with_codec stringCodec, priority -> "priority" with_codec intCodec'
            decoder = 'text <- "oldText" with_codec stringCodec' if version == 1 else 'body <- "message" with_codec stringCodec, priority <- "priority" with_codec intCodec'
            return text.replace("exposing [Delivery, Jobs]", "exposing [Delivery, Jobs, " + ", ".join(names) + "]").replace("jobs: [Delivery]", "jobs: [Delivery, " + ", ".join(names) + "]") + "".join(f'\nrecord {name} {{ {fields} }}\ncodec {name} {{ toJson {{ {codec} }} fromJson [ {{ {decoder} }} ] }}\n' for name in names)
        current = source / "schema/mail/v-current.tesl"
        current.write_text(add_other(current.read_text(), 1))
        entry = source / "app.tesl"
        jobs = ", ".join(f"Job Schema.Mail.VCurrent.{name} handle{name} Nothing" for name in names)
        handlers = "".join(f'\nworker handle{name}(job: Schema.Mail.VCurrent.{name} ::: FromQueue (Id == jobId) job) = job\n' for name in names)
        entry.write_text(entry.read_text().replace("jobs: [Job Schema.Mail.VCurrent.Delivery handle Nothing]", "jobs: [Job Schema.Mail.VCurrent.Delivery handle Nothing, " + jobs + "]") + handlers)
        def emit(version):
            target = CONFIG.artifacts / family / f"v{version}"
            target.mkdir(parents=True, exist_ok=True)
            generated = Path(tempfile.mkdtemp(prefix=f"build-v{version}-", dir=target_family)) / "go"
            for file in source.rglob("*.tesl"):
                require(run([CONFIG.compiler, "agent-context", file], env=self.env, timeout=build_timeout))
            require(run([CONFIG.compiler, "--backend", "go", entry, "--out", generated], env=self.env, timeout=build_timeout))
            require(run(["go", "build", "-race", "-o", target / "app", "./cmd/app"], cwd=generated, env=self.env, timeout=build_timeout))
        emit(1)
        preview = runpy.run_path(str(ROOT / "example/db-three-upgrades/run.py"))["apply_preview"]
        preview(CONFIG.compiler, entry, self.env, "generate", "--new-revision", timeout=build_timeout)
        current.write_text(add_other((CONFIG.artifacts / "queue/v2/source/schema/mail/v-current.tesl").read_text(), 2))
        helper = source / "migrations/mail/convert2.tesl"
        text = (CONFIG.artifacts / "queue/v2/source/migrations/mail/convert2.tesl").read_text()
        exports = ", ".join(f"convert{name}, fixture{name}" for name in names)
        text = text.replace("exposing [convert, repair, oldJob, rejectedJob]", "exposing [convert, repair, oldJob, rejectedJob, " + exports + "]")
        text += "".join(f'\nfn convert{name}(old: Schema.Mail.V1.{name}) -> Migrated Schema.Mail.VCurrent.{name} =\n  Row (Schema.Mail.VCurrent.{name} {{ body: old.text, priority: 11 }})\nfn fixture{name}() -> Schema.Mail.V1.{name} = Schema.Mail.V1.{name} {{ text: "other" }}\n' for name in names)
        helper.write_text(text)
        edge = source / "migrations/mail/v2.tesl"
        body = (CONFIG.artifacts / "queue/v2/source/migrations/mail/v2.tesl").read_text().split("module ", 1)[1]
        conversions = ", ".join(f"{name}: Migrate Schema.Mail.Migrate.Convert2.convert{name}" for name in names)
        fixtures = ", ".join(f"Schema.Mail.Migrate.Convert2.fixture{name}" for name in names)
        body = body.replace("Delivery: Migrate Schema.Mail.Migrate.Convert2.convert", "Delivery: Migrate Schema.Mail.Migrate.Convert2.convert, " + conversions)
        body = body.replace("[Schema.Mail.Migrate.Convert2.oldJob]", "[Schema.Mail.Migrate.Convert2.oldJob, " + fixtures + "]")
        edge.write_text(edge.read_text().split("module ", 1)[0] + "module " + body)
        preview(CONFIG.compiler, entry, self.env, "generate", timeout=build_timeout)
        emit(2)
        (target_family / "compiler.sha256").write_text(hashlib.sha256(CONFIG.compiler.read_bytes()).hexdigest() + "\n")


class SchedulerReview(unittest.TestCase):
    def setUp(self):
        self.family = f"fair-many-{CONFIG.scheduler_types}" if self._testMethodName.startswith("test_124_") else "fair"
        stamp = CONFIG.artifacts / self.family / "compiler.sha256"
        compiler_hash = hashlib.sha256(CONFIG.compiler.read_bytes()).hexdigest()
        if not (CONFIG.artifacts / self.family / "v2/app").exists() or not stamp.exists() or stamp.read_text().strip() != compiler_hash:
            LAB.build_fairness_payloads(self.family, CONFIG.scheduler_types - 1 if self.family.startswith("fair-many-") else 1)
        self.db = "review_fairness"
        LAB.sql("postgres", f"create database {self.db}")
        self.addCleanup(lambda: LAB.sql("postgres", f"drop database {self.db} with (force)"))
        LAB.sql("postgres", f"grant create on database {self.db} to review_owner")
        LAB.sql(self.db, "grant create on schema public to review_owner")
        require(LAB.install(self.db, "v1", self.family))
        LAB.stop(*LAB.start(self.db, "v1", self.family))
        require(LAB.install(self.db, "v2", self.family))

    def fill(self, prefix, count=512):
        LAB.sql(self.db, f"select mail.tesl_queue_enqueue(1,'Jobs','Delivery',{literal(prefix)}||n::text,'{{\"oldText\":\"busy\"}}') from generate_series(1,{count}) n", "review_request")

    def test_120_busy_first_type_does_not_starve_later_type(self):
        self.fill("initial-", 1024)
        LAB.sql(self.db, "select mail.tesl_queue_enqueue(1,'Jobs','Other','rare','{\"oldText\":\"rare-value\"}')", "review_request")
        stop = threading.Event()
        errors = []
        def producer():
            iteration = 0
            try:
                while not stop.is_set():
                    old = int(LAB.sql(self.db, "select count(*) from mail.tesl_jobs where job_type='Delivery' and schema_version=1"))
                    if old < 512:
                        self.fill(f"refill-{iteration}-")
                        iteration += 1
                    stop.wait(.05)
            except BaseException as error:
                errors.append(error)
        thread = threading.Thread(target=producer)
        thread.start()
        process = log = None
        try:
            process, log = LAB.start(self.db, "v2", "fair")
            LAB.wait(lambda: LAB.sql(self.db, "select schema_version=2 from mail.tesl_jobs where id='rare'") == "t", process)
            self.assertEqual(json.loads(LAB.sql(self.db, "select payload from mail.tesl_jobs where id='rare'")), {"message": "rare-value", "priority": 11})
            self.assertGreater(int(LAB.sql(self.db, "select count(*) from mail.tesl_jobs where job_type='Delivery' and schema_version=1")), 0)
        finally:
            stop.set()
            thread.join(timeout=10)
            if process is not None:
                LAB.stop(process, log)
        self.assertFalse(thread.is_alive())
        self.assertFalse(errors, errors)

    def test_121_restart_uses_durable_service_order(self):
        self.fill("before-restart-", 768)
        process, log = LAB.start(self.db, "v2", "fair")
        try:
            LAB.wait(lambda: LAB.sql(self.db, "select count(*)>0 from mail.tesl_row_queue_conversion_receipts") == "t", process)
        finally:
            LAB.stop(process, log)
        self.fill("after-restart-", 768)
        LAB.sql(self.db, "select mail.tesl_queue_enqueue(1,'Jobs','Other','restart-rare','{\"oldText\":\"restart\"}')", "review_request")
        process, log = LAB.start(self.db, "v2", "fair")
        try:
            LAB.wait(lambda: LAB.sql(self.db, "select schema_version=2 from mail.tesl_jobs where id='restart-rare'") == "t", process)
            self.assertGreater(int(LAB.sql(self.db, "select count(*) from mail.tesl_jobs where job_type='Delivery' and schema_version=1")), 0)
        finally:
            LAB.stop(process, log)

    def test_122_growing_receipt_history_keeps_indexed_service_lookup(self):
        self.fill("history-", 1024)
        started = time.monotonic()
        process, log = LAB.start(self.db, "v2", "fair")
        try:
            # A 1,024-transaction workload has its own budget; this is not an
            # assertion that the ordinary one-job readiness deadline must scale.
            LAB.wait(lambda: LAB.sql(self.db, "select count(*)=1024 from mail.tesl_row_queue_conversion_receipts") == "t", process, timeout=120)
        finally:
            LAB.stop(process, log)
        original = LAB.sql(self.db, "select count(*)::text||','||max(attempt_seq)::text from mail.tesl_row_queue_conversion_receipts")
        digest = LAB.sql(self.db, "select source_digest from mail.tesl_row_queue_conversion_staging where job_type='Delivery'")
        LAB.sql(self.db, "analyze mail.tesl_row_queue_conversion_receipts")
        plan = json.loads(LAB.sql(self.db, f"explain (analyze,buffers,format json) select attempt_seq from mail.tesl_row_queue_conversion_receipts where source_digest={literal(digest)} order by attempt_seq desc limit 1"))[0]
        rendered = json.dumps(plan)
        self.assertIn("tesl_row_queue_conversion_fair", rendered)
        self.assertNotIn("Seq Scan", rendered)
        before = self.state_for_scheduler()
        for _ in range(3):
            self.assertTrue(LAB.sql(self.db, "select source_digest from mail.tesl_row_queue_dispatch_sources()", "review_worker"))
        self.assertEqual(LAB.sql(self.db, "select count(*)::text||','||max(attempt_seq)::text from mail.tesl_row_queue_conversion_receipts"), original)
        self.assertEqual(self.state_for_scheduler(), before)
        (CONFIG.output / "scheduler-history-plan.json").write_text(json.dumps(plan, indent=2) + "\n")
        (CONFIG.output / "scheduler-history-workload.json").write_text(json.dumps({"rows": 1024, "seconds": time.monotonic()-started}, indent=2) + "\n")

    def state_for_scheduler(self):
        return LAB.sql(self.db, "select row_to_json(s)::text from mail.tesl_schema_state s")

    def test_124_multi_type_inventory_progresses_before_busy_head_drains(self):
        count = CONFIG.scheduler_types
        self.fill("many-busy-", 1024)
        LAB.sql(self.db, f"select mail.tesl_queue_enqueue(1,'Jobs','Other'||lpad(i::text,3,'0'),'many-'||i::text,'{{\"oldText\":\"many\"}}') from generate_series(0,{count - 2}) i", "review_request")
        process, log = LAB.start(self.db, "v2", self.family)
        try:
            LAB.wait(lambda: LAB.sql(self.db, f"select count(distinct job_type)={count} from mail.tesl_jobs where schema_version=2") == "t", process)
            self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_conversion_staging"), str(count))
            self.assertGreater(int(LAB.sql(self.db, "select count(*) from mail.tesl_jobs where schema_version=1")), 0)
            self.assertEqual(json.loads(LAB.sql(self.db, f"select payload from mail.tesl_jobs where job_type='Other{count - 2:03}' and schema_version=2 limit 1")), {"message": "many", "priority": 11})
            (CONFIG.output / "scheduler-inventory-workload.json").write_text(json.dumps({"types": count, "oldHeadRemaining": int(LAB.sql(self.db, "select count(*) from mail.tesl_jobs where job_type='Delivery' and schema_version=1"))}, indent=2) + "\n")
        finally:
            LAB.stop(process, log)


class KnownGaps(unittest.TestCase):
    def setUp(self):
        if not (CONFIG.artifacts / "mixed/v2/app").exists():
            LAB.build_mixed_payloads()
        db = "review_mixed"
        LAB.sql("postgres", f"create database {db}")
        self.addCleanup(lambda: LAB.sql("postgres", f"drop database {db} with (force)"))
        LAB.sql("postgres", f"grant create on database {db} to review_owner")
        LAB.sql(db, "grant create on schema public to review_owner")
        require(LAB.install(db, "v1", "mixed"))
        LAB.stop(*LAB.start(db, "v1", "mixed"))
        LAB.sql(db, "select mail.tesl_queue_enqueue(1,'Jobs','Unchanged','delayed','{\"text\":\"retained\"}')", "review_request")
        LAB.sql(db, "update mail.tesl_jobs set next_attempt_at='2099-01-01'")
        require(LAB.install(db, "v2", "mixed"))
        proc, log = LAB.start(db, "v2", "mixed")
        try:
            time.sleep(1)
            self.assertIsNone(proc.poll(), Path(log.name).read_text())
        finally:
            LAB.stop(proc, log)
        self.db = db
        self.claim = None
        if "dead_unchanged" in self._testMethodName:
            LAB.sql(db, "update mail.tesl_jobs set status='dead',dead_reason='attempts-exhausted',attempts=7")
        if "claim" in self._testMethodName:
            version = 2 if "surviving" in self._testMethodName else 1
            LAB.sql(db, "update mail.tesl_jobs set next_attempt_at=clock_timestamp()")
            self.claim = json.loads(LAB.sql(db, f"select row_to_json(c) from mail.tesl_queue_claim({version},'Jobs','pending','restamp-review',60000) c", "review_request"))
            if "expired" in self._testMethodName:
                LAB.sql(db, "update mail.tesl_jobs set lease_until=clock_timestamp()-interval '1 second'")
        if "changed_blocker" in self._testMethodName:
            LAB.sql(db, "select mail.tesl_queue_enqueue(1,'Jobs','Delivery','rejected','{\"oldText\":\"\"}')", "review_request")
        if "rollback" in self._testMethodName:
            self.result = None
            return
        self.result = LAB.schema(db, "v2", "contract", "V2", family="mixed")
        if self.result.returncode:
            self.assertIn("blocked by old payloads", self.result.stderr)
        self.assertEqual(LAB.sql(db, "select payload->>'text' from mail.tesl_jobs where id='delayed'"), "retained")

    def test_96_unchanged_delayed_job_must_not_block_changed_peer_retirement(self):
        self.assertEqual(self.result.returncode, 0, self.result.stderr)
        self.assertEqual(LAB.sql("review_mixed", "select schema_version||','||(next_attempt_at='2099-01-01'::timestamptz)::text from mail.tesl_jobs where id='delayed'"), "2,true")
        self.assertEqual(LAB.sql("review_mixed", "select count(*) from mail.tesl_row_queue_restamps"), "1")
        require(LAB.schema("review_mixed", "v2", "contract", "V2", family="mixed"))
        self.assertEqual(LAB.sql("review_mixed", "select count(*) from mail.tesl_row_queue_restamps"), "1")

    def test_108_dead_unchanged_job_preserves_attempts_and_schedule(self):
        require(self.result)
        self.assertEqual(LAB.sql(self.db, "select schema_version||','||status||','||attempts||','||(next_attempt_at='2099-01-01'::timestamptz)::text from mail.tesl_jobs"), "2,dead,7,true")

    def test_109_live_old_claim_blocks_without_partial_restamp(self):
        self.assertNotEqual(self.result.returncode, 0)
        self.assertEqual(LAB.sql(self.db, "select schema_version||','||status from mail.tesl_jobs"), "1,processing")
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_restamps"), "0")
        self.assertEqual(LAB.sql(self.db, "select min_version from mail.tesl_schema_state"), "1")

    def test_110_expired_old_claim_is_released_and_audited(self):
        require(self.result)
        self.assertEqual(LAB.sql(self.db, "select schema_version||','||status||','||(claim_token is null)::text from mail.tesl_jobs"), "2,pending,true")
        self.assertEqual(LAB.sql(self.db, "select claim_seq from mail.tesl_row_queue_restamps"), str(self.claim["attempt_seq"]))

    def test_111_surviving_claim_keeps_completion_right(self):
        require(self.result)
        self.assertEqual(LAB.sql(self.db, "select claim_token from mail.tesl_jobs"), self.claim["token"])
        self.assertEqual(LAB.sql(self.db, f"select mail.tesl_queue_complete(2,'Jobs','delayed',{literal(self.claim['token'])},{self.claim['attempt_seq']})", "review_request"), "t")
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_restamps"), "1")
        require(LAB.schema(self.db, "v2", "status", role="review_request", family="mixed"))

    def test_112_changed_blocker_rolls_back_all_restamp_progress(self):
        self.assertNotEqual(self.result.returncode, 0)
        self.assertEqual(LAB.sql(self.db, "select schema_version from mail.tesl_jobs where id='delayed'"), "1")
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_restamps"), "0")

    def test_113_retirement_rollback_restores_job_audit_and_floors(self):
        # Independent canonical framing oracle; execute the real protected Worker
        # operation with both fences, then roll back its entire transaction.
        header = json.loads(LAB.sql(self.db, "select json_build_array(m.database_uuid::text,m.fence_ns::text,r.family,p.contract_hash,q.inventory_hash,p.compiler_abi) from mail.tesl_schema_meta m cross join mail.tesl_row_versions r cross join mail.tesl_row_physical p cross join mail.tesl_queue_versions q where m.id=1 and r.version=1 and p.version=2 and q.version=2"))
        sources = json.loads(LAB.sql(self.db, "select json_agg(json_build_array(queue,job_type,revision::text,source_digest) order by queue collate \"C\",job_type collate \"C\",revision) from mail.tesl_row_queue_conversion_staging where from_version=1"))
        def frame(value):
            if isinstance(value, list):
                return f"l{len(value)}:".encode() + b"".join(frame(x) for x in value)
            raw = value.encode()
            return f"s{len(raw)}:".encode() + raw
        uuid, fence, family, physical, inventory, abi = header
        raw = frame(["tesl-migration-canonical", "1", "migration", ["tesl-row-queue-retirement-v1", uuid, fence, family, "mail", "1", "2", physical, inventory, sources, abi]])
        query = f"begin; select pg_advisory_xact_lock({fence},1); select pg_advisory_xact_lock(-{fence},1); select mail.tesl_retire_row_queue({literal(uuid)},{fence},decode('{raw.hex()}','hex'),'{hashlib.sha256(raw).hexdigest()}',{literal(abi)}); select mail.tesl_row_queue_final(2); rollback;"
        output = LAB.sql(self.db, query, "review_worker")
        self.assertIn("t", output.splitlines())
        self.assertEqual(LAB.sql(self.db, "select schema_version from mail.tesl_jobs"), "1")
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_restamps"), "0")
        self.assertEqual(LAB.sql(self.db, "select min_version from mail.tesl_schema_state"), "1")
        require(LAB.schema(self.db, "v2", "contract", "V2", family="mixed"))


LAB = None


class DatabaseReview(unittest.TestCase):
    def setUp(self):
        template = "review_v1" if "_budget_" in self._testMethodName else "review_retired" if "retired_" in self._testMethodName else "review_v2"
        self.db = LAB.clone(template)

    def tearDown(self):
        LAB.sql("postgres", f"drop database {self.db} with (force)")

    def state(self):
        return LAB.sql(self.db, "select row_to_json(s)::text from mail.tesl_schema_state s")

    def assertRefused(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("panic:", result.stderr)

    def enqueue(self, payload, identity="attack", version=1):
        LAB.sql(self.db, f"select mail.tesl_queue_enqueue({version},'Jobs','Delivery',{literal(identity)},{literal(json.dumps(payload))}::jsonb)", "review_request")

    def convert(self, release="v2", expected="converted"):
        process, log = LAB.start(self.db, release)
        try:
            LAB.wait(lambda: LAB.sql(self.db, f"select exists(select 1 from mail.tesl_row_queue_conversion_receipts where kind={literal(expected)})") == "t", process)
        finally:
            LAB.stop(process, log)

    def test_41_future_contract_does_not_replay_prior_retirement(self):
        before = self.state()
        self.assertRefused(LAB.schema(self.db, "v3", "contract", "V3"))
        self.assertEqual(self.state(), before)

    def test_42_new_edge_cannot_stage_before_retirement(self):
        before = self.state()
        self.assertRefused(LAB.install(self.db, "v3"))
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_conversion_staging where to_version=3"), "0")
        self.assertEqual(self.state(), before)

    def test_43_delayed_job_converts_without_running_handler(self):
        self.enqueue({"oldText": "future"})
        LAB.sql(self.db, "update mail.tesl_jobs set next_attempt_at='2099-01-01',attempts=5")
        self.convert()
        self.assertEqual(LAB.sql(self.db, "select schema_version||','||attempts||','||(next_attempt_at='2099-01-01'::timestamptz)::text||','||status from mail.tesl_jobs"), "2,5,true,pending")

    def test_44_dead_job_preserves_retry_disposition(self):
        self.enqueue({"oldText": "dead"})
        LAB.sql(self.db, "update mail.tesl_jobs set status='dead',dead_reason='attempts-exhausted',attempts=7,next_attempt_at='infinity'")
        self.convert()
        self.assertEqual(LAB.sql(self.db, "select schema_version||','||attempts||','||status||','||dead_reason||','||next_attempt_at::text from mail.tesl_jobs"), "2,7,dead,attempts-exhausted,infinity")

    def test_45_live_old_claim_is_not_rewritten(self):
        self.enqueue({"oldText": "leased"})
        claim = LAB.sql(self.db, "select row_to_json(c) from mail.tesl_queue_claim(1,'Jobs','pending','review',60000) c", "review_request")
        self.assertTrue(claim)
        self.convert_no_progress()
        self.assertEqual(LAB.sql(self.db, "select schema_version||','||status from mail.tesl_jobs"), "1,processing")
        self.assertRefused(LAB.schema(self.db, "v2", "contract", "V2"))

    def convert_no_progress(self):
        process, log = LAB.start(self.db, "v2")
        try:
            time.sleep(.8)
            self.assertIsNone(process.poll(), Path(log.name).read_text())
            self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_conversion_receipts"), "0")
        finally:
            LAB.stop(process, log)

    def test_46_expired_claim_is_recoverable(self):
        self.enqueue({"oldText": "expired"})
        LAB.sql(self.db, "select * from mail.tesl_queue_claim(1,'Jobs','pending','review',60000)", "review_request")
        LAB.sql(self.db, "update mail.tesl_jobs set lease_until=clock_timestamp()-interval '1 second'")
        self.convert()
        self.assertEqual(LAB.sql(self.db, "select schema_version||','||status||','||(claim_token is null)::text from mail.tesl_jobs"), "2,pending,true")

    def test_47_repair_cannot_sanitize_invalid_historical_shape(self):
        self.enqueue({"oldText": 42})
        self.convert(expected="payload-invalid")
        require(LAB.install(self.db, "v2-repair"))
        process, log = LAB.start(self.db, "v2-repair")
        try:
            time.sleep(.8)
            self.assertIsNone(process.poll(), Path(log.name).read_text())
            self.assertEqual(LAB.sql(self.db, "select schema_version||','||dead_reason from mail.tesl_jobs"), "1,payload-invalid")
            self.assertRefused(LAB.schema(self.db, "v2-repair", "contract", "V2"))
        finally:
            LAB.stop(process, log)

    def test_48_rejection_keeps_original_and_repair_extends_receipts(self):
        self.enqueue({"oldText": ""})
        self.convert(expected="migration-rejected")
        original = LAB.sql(self.db, "select row_to_json(r)::text from mail.tesl_row_queue_conversion_receipts r")
        require(LAB.install(self.db, "v2-repair"))
        self.convert("v2-repair")
        self.assertEqual(LAB.sql(self.db, "select row_to_json(r)::text from mail.tesl_row_queue_conversion_receipts r where kind='migration-rejected'"), original)
        self.assertEqual(LAB.sql(self.db, "select payload->>'message' from mail.tesl_jobs"), "repaired")
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_conversion_receipts"), "2")

    def test_49_retired_source_enqueue_refuses_without_row(self):
        self.assertNotEqual(LAB.sql(self.db, "select mail.tesl_queue_enqueue(1,'Jobs','Delivery','late','{\"oldText\":\"late\"}')", "review_request", ok=False).returncode, 0)
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_jobs"), "0")

    def test_50_retired_history_visible_to_original_status(self):
        status = json.loads(require(LAB.schema(self.db, "v1", "status", role="review_request")))
        self.assertEqual(status["currentVersion"], 2)
        self.assertEqual(status["minVersion"], 2)

    def test_51_retired_repair_install_replays_only_existing_revision(self):
        before = LAB.sql(self.db, "select string_agg(row_to_json(s)::text,'|' order by revision) from mail.tesl_row_queue_conversion_staging s")
        require(LAB.install(self.db, "v2-repair"))
        self.assertEqual(LAB.sql(self.db, "select string_agg(row_to_json(s)::text,'|' order by revision) from mail.tesl_row_queue_conversion_staging s"), before)

    def test_52_recent_instance_blocks_empty_queue_contract(self):
        LAB.sql(self.db, "insert into mail.tesl_schema_instances values('recent',1,1,clock_timestamp(),1)")
        before = self.state()
        result = LAB.schema(self.db, "v2", "contract", "V2")
        self.assertRefused(result)
        self.assertIn("recent retiring instances", result.stderr)
        self.assertEqual(self.state(), before)

    def test_53_audited_job_id_cannot_be_reused(self):
        self.enqueue({"oldText": "keep"})
        self.convert()
        LAB.sql(self.db, "delete from mail.tesl_jobs")
        result = LAB.sql(self.db, "select mail.tesl_queue_enqueue(2,'Jobs','Delivery','attack','{\"message\":\"new\",\"priority\":7}')", "review_request", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_conversion_receipts"), "1")

    def test_54_stale_claim_token_cannot_complete_converted_job(self):
        self.enqueue({"oldText": "keep"})
        old = json.loads(LAB.sql(self.db, "select row_to_json(c) from mail.tesl_queue_claim(1,'Jobs','pending','review',60000) c", "review_request"))
        LAB.sql(self.db, "update mail.tesl_jobs set lease_until=clock_timestamp()-interval '1 second'")
        self.convert()
        self.assertEqual(LAB.sql(self.db, f"select mail.tesl_queue_complete(1,'Jobs','attack',{literal(old['token'])},{old['attempt_seq']})", "review_request"), "f")
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_jobs"), "1")

    def budget_binary(self, mutual=False):
        prefix = "budget-mutual-" if mutual else "budget-tail-"
        target = Path(tempfile.mkdtemp(prefix=prefix, dir=CONFIG.artifacts / "queue"))
        label = target.name
        source = target / "source"
        shutil.copytree(CONFIG.artifacts / "queue/v2/source", source)
        helper = source / "migrations/mail/convert2.tesl"
        text = helper.read_text()
        expression = "Row (Schema.Mail.VCurrent.Delivery { body: old.text, priority: 7 })"
        self.assertIn(expression, text)
        text = text.replace(expression, "again old" if mutual else "convert old")
        if mutual:
            text += "\nfn again(old: Schema.Mail.V1.Delivery) -> Migrated Schema.Mail.VCurrent.Delivery = convert old\n"
        helper.write_text(text)
        require(run([CONFIG.compiler, "agent-context", helper], env=LAB.env))
        require(run([CONFIG.compiler, "--backend", "go", source / "app.tesl", "--out", target / "go"], env=LAB.env))
        require(run(["go", "build", "-race", "-o", target / "app", "./cmd/app"], cwd=target / "go", env=LAB.env))
        return label

    def assert_budget_stops(self, mutual=False):
        label = self.budget_binary(mutual)
        self.enqueue({"oldText": "keep"})
        original = LAB.sql(self.db, "select payload::text from mail.tesl_jobs")
        require(LAB.install(self.db, label))
        result = LAB.schema(self.db, label, "worker")
        self.assertRefused(result)
        self.assertIn("migration execution stopped", result.stderr)
        self.assertEqual(LAB.sql(self.db, "select payload::text from mail.tesl_jobs"), original)
        self.assertEqual(LAB.sql(self.db, "select schema_version||','||status from mail.tesl_jobs"), "1,pending")
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_conversion_receipts"), "0")
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_conversion_attempts"), "0")

    def test_114_budget_tail_recursion_stops_without_publication(self):
        self.assert_budget_stops()

    def test_115_budget_mutual_recursion_stops_without_stack_overflow(self):
        self.assert_budget_stops(True)

    def test_116_public_status_distinguishes_repair_and_invalid_bytes(self):
        self.enqueue({"oldText": ""}, "rejected")
        self.enqueue({"oldText": 42, "private": "secret-retained-value"}, "invalid")
        self.convert(expected="migration-rejected")
        self.convert(expected="payload-invalid")
        LAB.wait(lambda: LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_conversion_receipts") == "2")
        before = self.state()
        response = LAB.schema(self.db, "v2", "status", role="review_request")
        status = json.loads(require(response))
        summary = status["queues"]
        self.assertEqual(summary["rejected"], 1)
        self.assertEqual(summary["invalid"], 1)
        self.assertEqual(summary["oldPayloads"], 2)
        self.assertEqual({b["code"] for b in summary["blockers"]}, {"QUEUE_MIGRATION_REJECTED", "QUEUE_PAYLOAD_INVALID"})
        self.assertNotIn("secret-retained-value", response.stdout)
        self.assertNotIn('"original":', response.stdout)
        self.assertEqual(self.state(), before)
        require(LAB.install(self.db, "v2-repair"))
        repaired = json.loads(require(LAB.schema(self.db, "v2-repair", "status", role="review_request")))
        self.assertEqual(repaired["queues"]["jobs"][0]["repairRevision"], 1)

    def test_117_public_status_includes_recent_retiring_instances(self):
        LAB.sql(self.db, "insert into mail.tesl_schema_instances values('old-live',1,1,clock_timestamp(),1); insert into mail.tesl_schema_instances values('stale',1,1,clock_timestamp()-interval '1 minute',1)")
        status = json.loads(require(LAB.schema(self.db, "v2", "status", role="review_request")))
        self.assertEqual([item["instance"] for item in status["instances"]], ["old-live"])
        self.assertEqual(status["queues"]["recentRetiringInstances"], 1)
        self.assertIn("RECENT_RETIRING_INSTANCES", [item["code"] for item in status["queues"]["blockers"]])

    def test_118_public_status_reports_old_claim_lease_blocker(self):
        self.enqueue({"oldText": "leased"})
        LAB.sql(self.db, "select * from mail.tesl_queue_claim(1,'Jobs','pending','claimant',60000)", "review_request")
        status = json.loads(require(LAB.schema(self.db, "v2", "status", role="review_request")))
        self.assertEqual(status["queues"]["liveRetiringClaims"], 1)
        self.assertIn("QUEUE_RETIRING_CLAIMS", [item["code"] for item in status["queues"]["blockers"]])


# Each mutation changes a different authority or catalog invariant, and must be
# admitted by PostgreSQL itself before the public read-only status is exercised.
CORRUPTIONS = [
    ("01_installation_uuid", "update mail.tesl_schema_meta set database_uuid=gen_random_uuid()"),
    ("02_fence_namespace", "update mail.tesl_schema_meta set fence_ns=fence_ns+1"),
    ("03_unsupported_catalog", "update mail.tesl_schema_meta set format_version=99"),
    ("04_fabricated_floor", "update mail.tesl_schema_state set min_version=2,compat_floor=2"),
    ("05_missing_expansion", "delete from mail.tesl_schema_versions where version=2 and step='expanded'"),
    ("06_wrong_expansion_digest", "update mail.tesl_schema_versions set artefact_hash=repeat('a',64) where version=2"),
    ("07_wrong_expansion_abi", "update mail.tesl_schema_versions set source_abi='tesl-source-abi-v1:'||repeat('a',64) where version=2"),
    ("08_target_staging_uuid", "update mail.tesl_row_queue_target_staging set database_uuid=gen_random_uuid()"),
    ("09_root_staging_fence", "update mail.tesl_row_queue_conversion_staging set fence_ns=fence_ns+1"),
    ("10_target_predecessor", "update mail.tesl_row_queue_target_staging set predecessor_hash=repeat('a',64)"),
    ("11_missing_root_source", "delete from mail.tesl_row_queue_conversion_staging"),
    ("12_rehashed_payload_contract", "update mail.tesl_queue_payloads set contract=contract||'x'::bytea,contract_hash=encode(sha256(contract||'x'::bytea),'hex') where version=2"),
    ("13_queue_membership_count", "update mail.tesl_queue_contracts set payload_count=2 where version=2"),
    ("14_source_snapshot", "update mail.tesl_queue_versions set schema_snapshot_hash=repeat('a',64) where version=2"),
    ("15_source_storage", "update mail.tesl_queue_versions set storage_snapshot_hash=repeat('a',64) where version=2"),
    ("16_queue_source_receipt", "update mail.tesl_row_queue_sources set expansion_hash=repeat('a',64) where version=2"),
    ("17_epoch_preserving_lie", "update mail.tesl_row_physical set epoch_preserving=true where version=2"),
    ("18_missing_target_staging", "delete from mail.tesl_row_queue_target_staging"),
    ("19_request_raw_payload_grant", "grant select on mail.tesl_jobs to review_request"),
    ("20_worker_raw_receipt_grant", "grant select on mail.tesl_row_queue_conversion_receipts to review_worker"),
    ("21_public_function_execute", "grant execute on function mail.tesl_retire_row_queue(text,integer,bytea,text,text) to public"),
    ("22_weaken_job_constraint", "alter table mail.tesl_jobs drop constraint tesl_jobs_schema_version_check"),
    ("23_unlogged_jobs", "alter table mail.tesl_jobs set unlogged"),
    ("24_sequence_rewind_policy", "alter sequence mail.tesl_jobs_seq_seq increment by 2"),
    ("25_retired_rehashed_receipt", "update mail.tesl_row_queue_retirements set retirement=retirement||'x'::bytea,retirement_hash=encode(sha256(retirement||'x'::bytea),'hex')"),
    ("26_retired_missing_receipt", "delete from mail.tesl_row_queue_retirements"),
    ("27_retired_repair_gap", "delete from mail.tesl_row_queue_conversion_staging where revision=1"),
    ("28_retired_wrong_lifecycle", "update mail.tesl_schema_versions set artefact_hash=repeat('a',64) where version=2 and step='contracted'"),
    ("123_missing_fairness_index", "drop index mail.tesl_row_queue_conversion_fair"),
]


def corruption_case(sql):
    def test(self):
        LAB.sql(self.db, sql)
        before = self.state()
        self.assertRefused(LAB.schema(self.db, "v2-repair", "status", role="review_request"))
        self.assertEqual(self.state(), before, "read-only refusal changed admission")
    return test


for name, mutation in CORRUPTIONS:
    setattr(DatabaseReview, "test_" + name, corruption_case(mutation))


def role_case(role, args):
    def test(self):
        before = self.state()
        self.assertRefused(LAB.schema(self.db, "v2", *args, role=role))
        self.assertEqual(self.state(), before)
    return test


for number, (role, args) in enumerate([
    ("review_request", ["install", "--worker", "review_worker", "--request", "review_request"]),
    ("review_worker", ["install", "--worker", "review_worker", "--request", "review_request"]),
    ("review_request", ["worker"]), ("review_installer", ["worker"]),
    ("review_request", ["contract", "V2"]), ("review_installer", ["contract", "V2"]),
    ("review_worker", ["close-epoch", "--through", "V2", "--force"]),
    ("review_worker", ["contract", "V0"]), ("review_worker", ["contract", "V3"]),
    ("review_worker", ["contract", "V2", "--force"]),
    ("review_worker", ["contract", "V2", "--database", "Other.Main"]),
    ("review_installer", ["install", "--worker", "review_request", "--request", "review_worker"]),
], 29):
    setattr(DatabaseReview, f"test_{number:02}_principal_or_command_{role}_{'_'.join(args).replace('-', '')}", role_case(role, args))


VALUES = [
    ("55_combining_unicode", "e\u0301"), ("56_non_bmp", "🙂𐐷"),
    ("57_rtl", "مرحبا\u202eabc"), ("58_json_escapes", 'quote" slash\\ newline\n tab\t'),
    ("59_sql_metacharacters", "'); DROP TABLE mail.tesl_jobs; --"),
    ("60_whitespace_not_empty", " \t\n"), ("61_long_text", "a" * 65536),
    ("62_frame_delimiters", "l4:s1:x|queue\x1fjob"),
    ("63_integer_looking_text", "900719925474099312345678901234567890"),
    ("64_json_looking_text", '{"priority":null,"__proto__":{}}'),
]


def value_case(value):
    def test(self):
        self.enqueue({"oldText": value})
        self.convert()
        self.assertEqual(json.loads(LAB.sql(self.db, "select payload from mail.tesl_jobs")), {"message": value, "priority": 7})
        receipt = LAB.sql(self.db, "select row_to_json(r) from mail.tesl_row_queue_conversion_receipts r")
        self.convert()
        self.assertEqual(LAB.sql(self.db, "select row_to_json(r) from mail.tesl_row_queue_conversion_receipts r"), receipt)
    return test


for name, value in VALUES:
    setattr(DatabaseReview, "test_" + name, value_case(value))


class SourceReview(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="source-review05-", dir=CONFIG.output)
        self.source = Path(self.temp.name) / "source"
        shutil.copytree(CONFIG.artifacts / "queue/v2-repair/source", self.source)

    def tearDown(self):
        self.temp.cleanup()

    def check(self, relative):
        result = run([CONFIG.compiler, "agent-context", self.source / relative], env=LAB.env)
        self.assertIn(result.returncode, (0, 1), result.stderr)
        context = json.loads(result.stdout)
        self.assertEqual(context["ok"], result.returncode == 0)
        return context

    def mutate(self, relative, before, after):
        file = self.source / relative
        original = file.read_text()
        self.assertIn(before, original)
        file.write_text(original.replace(before, after, 1))
        return self.check(relative)

    def test_81_frozen_old_codec_edit_refuses_full_application(self):
        self.mutate("schema/mail/v1.tesl", '"oldText"', '"changed"')
        context = self.check("app.tesl")
        self.assertFalse(context["ok"])
        self.assertIn("MIG013", [d["code"] for d in context["diagnostics"]])

    def test_82_proof_forgery_refuses_current_write(self):
        shutil.rmtree(self.source)
        shutil.copytree(CONFIG.artifacts / "row/v4/source", self.source)
        context = self.mutate("app.tesl", 'case tryTitle "repaired"', 'case tryTitle "kept"')
        context = self.mutate("app.tesl", "set note.title = title", 'set note.title = "unproved"')
        self.assertFalse(context["ok"])
        self.assertTrue(any(d["code"] == "V001" and "does not statically satisfy" in d["message"] for d in context["diagnostics"]), context)

    def test_83_revalidate_cannot_change_underlying_title(self):
        shutil.rmtree(self.source)
        shutil.copytree(CONFIG.artifacts / "row/v4/source", self.source)
        context = self.mutate("migrations/notes/v4.tesl", "tryTitle old.title", 'tryTitle "substitute"')
        self.assertFalse(context["ok"])
        self.assertIn("MIG", str(context["diagnostics"]))

    def test_84_same_cannot_cast_changed_metadata(self):
        shutil.rmtree(self.source)
        shutil.copytree(CONFIG.artifacts / "row/v4/source", self.source)
        self.mutate("schema/notes/v-current.tesl", 'body -> "body"', 'body -> "changed"')
        context = self.check("migrations/notes/v4.tesl")
        self.assertFalse(context["ok"])
        self.assertTrue(any(d["code"].startswith("MIG") for d in context["diagnostics"]))

    def test_85_pure_recursion_is_not_a_termination_proof(self):
        # Characterization: purity/type checking accepts recursion. Never execute
        # this callback in-process; totality is explicitly a remaining obligation.
        context = self.mutate("migrations/mail/convert2.tesl", "Row (Schema.Mail.VCurrent.Delivery { body: old.text, priority: 7 })", "convert old")
        self.assertTrue(context["ok"], context)

    def test_104_sql_update_cannot_invalidate_sibling_proof(self):
        file = self.source / "sibling.tesl"
        file.write_text('''module Sibling exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.DB exposing [dbWrite]
fact Above (lower: Int) (value: Int)
entity Item table "items" primaryKey id { id: String, lower: Int, upper: Int ::: Above lower upper }
fn attempt() -> String requires [dbWrite Item] =
  update item in Item
    where item.id == "one"
    set item.lower = 1000000
  "done"
''')
        context = self.check("sibling.tesl")
        self.assertFalse(any(d["code"] == "E000" for d in context["diagnostics"]), context)
        self.assertFalse(context["ok"], context)


class EmbeddedDocsReview(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="review05-installed-", dir="/tmp")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / "tesl"
        shutil.copyfile(CONFIG.compiler, cls.binary)
        cls.binary.chmod(0o700)
        cls.env = {k: v for k, v in os.environ.items() if not k.startswith("TESL_")}

    def document(self, name):
        return require(run([self.binary, "help", "manual", name], cwd=self.temp.name, env=self.env))

    def test_97_installed_queue_lesson_reports_current_scope(self):
        text = self.document("lesson96-typed-queue-conversion")
        self.assertIn("--schema contract Vn", text)
        self.assertNotIn("production worker dispatch remain pending", text)
        self.assertNotIn("public changed-payload dispatch and", text)

    def test_98_installed_lesson_does_not_claim_purity_is_totality(self):
        self.assertIn("Purity is **not totality**", self.document("lesson96-typed-queue-conversion"))

    def test_99_installed_lesson_names_unchanged_job_blocker(self):
        self.assertIn("delayed unchanged job", self.document("lesson96-typed-queue-conversion"))

    def test_100_linked_queue_example_is_embedded(self):
        self.assertIn("seven standalone binaries", self.document("example/queue-three-upgrades/README"))

    def test_101_linked_row_example_is_embedded(self):
        text = self.document("example/db-three-upgrades/README")
        self.assertIn("Revalidate", text)
        self.assertIn("Legacy", text)

    def test_102_queue_runner_source_is_embedded(self):
        self.assertIn("def exercise(output, env):", self.document("example/queue-three-upgrades/run.py"))

    def test_103_proof_revalidation_source_is_embedded(self):
        self.assertIn("Revalidate title", self.document("example/db-three-upgrades/transitions/v4.tesl"))

    def test_119_installed_operator_guide_has_roles_and_blocker_actions(self):
        text = self.document("migration-operations")
        self.assertIn("Short-lived installer", text)
        self.assertIn("QUEUE_PAYLOAD_INVALID", text)
        self.assertIn("QUEUE_RETIRING_CLAIMS", text)
        self.assertIn("100,000", text)


SOURCE_ATTACKS = [
    ("65_empty_fixture_set", "migrations/mail/v2.tesl", "[Schema.Mail.Migrate.Convert2.oldJob]", "[]", "MIG003"),
    ("66_duplicate_job_alias", "migrations/mail/v2.tesl", "Delivery: Migrate Schema.Mail.Migrate.Convert2.convert", "Delivery: Migrate Schema.Mail.Migrate.Convert2.convert, Delivery: Migrate Schema.Mail.Migrate.Convert2.convert", "MIG"),
    ("67_missing_changed_job", "migrations/mail/v2.tesl", "Delivery: Migrate Schema.Mail.Migrate.Convert2.convert", "", "MIG028"),
    ("68_unknown_job", "migrations/mail/v2.tesl", "Delivery: Migrate", "Missing: Migrate", "MIG"),
    ("69_repair_zero_revision", "migrations/mail/repair2.tesl", "revision: 1", "revision: 0", "MIG028"),
    ("70_repair_revision_gap", "migrations/mail/repair2.tesl", "revision: 1", "revision: 3", "MIG028"),
    ("71_repair_foreign_job", "migrations/mail/repair2.tesl", 'job: "Delivery"', 'job: "Other"', "MIG028"),
    ("72_repair_reuses_root_callback", "migrations/mail/repair2.tesl", "Convert2.repair", "Convert2.convert", "MIG028"),
    ("73_repair_unknown_field", "migrations/mail/repair2.tesl", "revision: 1", "revision: 1, discard: True", "MIG020"),
    ("74_repair_missing_fixture", "migrations/mail/repair2.tesl", "[Schema.Mail.Migrate.Convert2.rejectedJob]", "[]", "MIG003"),
    ("75_repair_unqualified_parent", "migrations/mail/repair2.tesl", "Schema.Mail.Migrate.V2.migration", "migration", "MIG020"),
    ("76_repair_not_runtime_value", "migrations/mail/repair2.tesl", "repair = QueueRepair", "other = QueueRepair", "MIG020"),
    ("77_converter_wrong_return", "migrations/mail/convert2.tesl", "priority: 7", 'priority: "wrong"', "T"),
    ("78_private_bad_body", "migrations/mail/convert2.tesl", 'fn convert(', 'fn hidden() -> Int = "wrong"\nfn convert(', "T"),
    ("79_duplicate_repair_revision_field", "migrations/mail/repair2.tesl", "revision: 1", "revision: 1, revision: 2", "MIG023"),
    ("80_predecessor_arbitrary_value", "migrations/mail/repair2.tesl", "Schema.Mail.Migrate.V2.migration", "Schema.Mail.Migrate.V2.something", "MIG020"),
]


def source_case(relative, before, after, code):
    def test(self):
        context = self.mutate(relative, before, after)
        self.assertFalse(context["ok"], context)
        self.assertTrue(any(d["code"].startswith(code) for d in context["diagnostics"]), context)
    return test


for name, *args in SOURCE_ATTACKS:
    setattr(SourceReview, "test_" + name, source_case(*args))


def sql_write_case(body, valid=False):
    def test(self):
        # No version metadata: the ordinary language must protect writes too.
        file = self.source / "sql-proof.tesl"
        file.write_text('''module SqlProof exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbWrite]
fact Allowed (value: String)
establish validate(value: String) -> Maybe (v: String ::: Allowed v) =
  if value == "blocked" then
    Nothing
  else
    Something (value ::: Allowed value)
entity Item table "items" primaryKey id { id: String, title: String ::: Allowed title, count: Int }
fn attempt() -> String requires [dbWrite Item] =
''' + body + '\n')
        context = self.check("sql-proof.tesl")
        self.assertFalse(any(d["code"] == "E000" for d in context["diagnostics"]), context)
        self.assertEqual(context["ok"], valid, context)
    return test


for number, name, body, valid in [
    (86, "update_wrong_scalar_type", '  update item in Item\n    where item.id == "one"\n    set item.count = "oops"\n  "done"', False),
    (87, "update_raw_proven_field", '  update item in Item\n    where item.id == "one"\n    set item.title = "blocked"\n  "done"', False),
    (88, "update_wrong_boolean_type", '  update item in Item\n    where item.id == "one"\n    set item.count = True\n  "done"', False),
    (89, "insert_raw_proven_field", '  let _ = insert Item { id: "one", title: "blocked", count: 1 }\n  "done"', False),
    (90, "upsert_raw_proven_field", '  let _ = upsert Item { id: "one", title: "blocked", count: 1 } onConflict [id] doUpdate [title]\n  "done"', False),
    (91, "update_checked_success", '  case validate "kept" of\n    Nothing -> "invalid"\n    Something title ->\n      update item in Item\n        where item.id == "one"\n        set item.title = title\n      "done"', True),
    (92, "checked_other_value_not_proof", '  case validate "kept" of\n    Nothing -> "invalid"\n    Something title ->\n      update item in Item\n        where item.id == "one"\n        set item.title = "blocked"\n      "done"', False),
    (93, "insert_checked_success", '  case validate "kept" of\n    Nothing -> "invalid"\n    Something title ->\n      let _ = insert Item { id: "one", title: title, count: 1 }\n      "done"', True),
    (94, "update_computation_loses_proof", '  case validate "kept" of\n    Nothing -> "invalid"\n    Something title ->\n      update item in Item\n        where item.id == "one"\n        set item.title = title ++ "changed"\n      "done"', False),
    (95, "insert_many_wrong_element_type", '  let rows = [42]\n  let _ = insertMany rows in Item\n  "done"', False),
]:
    setattr(SourceReview, f"test_{number}_{name}", sql_write_case(body, valid))


def sibling_case(assignments, valid):
    def test(self):
        file = self.source / "sibling.tesl"
        file.write_text('''module Sibling exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbWrite]
fact Above (lower: Int) (value: Int)
establish bounded(lower: Int, value: Int) -> Maybe (v: Int ::: Above lower v) =
  if value > lower then
    Something (value ::: Above lower value)
  else
    Nothing
entity Item table "items" primaryKey id { id: String, lower: Int, upper: Int ::: Above lower upper }
fn attempt() -> String requires [dbWrite Item] =
  let lower = 1
  case bounded lower 2 of
    Nothing -> "invalid"
    Something upper ->
      update item in Item
        where item.id == "one"
''' + assignments + '\n      "done"\n')
        context = self.check("sibling.tesl")
        self.assertFalse(any(d["code"] == "E000" for d in context["diagnostics"]), context)
        self.assertEqual(context["ok"], valid, context)
    return test


for number, name, assignments, valid in [
    (105, "dependent_fields_checked_together", "        set item.lower = lower\n        set item.upper = upper", True),
    (106, "dependent_proof_wrong_assigned_subject", "        set item.lower = 1000000\n        set item.upper = upper", False),
    (107, "proof_cannot_assume_existing_sibling_value", "        set item.upper = upper", False),
]:
    setattr(SourceReview, f"test_{number}_{name}", sibling_case(assignments, valid))


def main():
    global CONFIG, LAB
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--compiler", type=Path, default=ROOT / "compiler/_build/default/bin/main.exe")
    parser.add_argument("--match", default="", help="run named cases containing this substring")
    parser.add_argument("--scheduler-types", type=int, default=17, help="job types for case 124 (3–257)")
    CONFIG = parser.parse_args()
    if not 3 <= CONFIG.scheduler_types <= 257:
        parser.error("--scheduler-types must be between 3 and 257")
    CONFIG.artifacts = CONFIG.artifacts.resolve()
    CONFIG.output = CONFIG.output.resolve()
    CONFIG.output.mkdir(parents=True, exist_ok=True)
    if CONFIG.build:
        for family, example in (("queue", "queue-three-upgrades"), ("row", "db-three-upgrades")):
            require(run(["python3", ROOT / "example" / example / "run.py", "--output", CONFIG.artifacts / family, "--build-only"], timeout=1200))
    LAB = Lab()
    try:
        LAB.prepare()
        suite = unittest.TestSuite()
        names = []
        for cls in (DatabaseReview, SourceReview, KnownGaps, EmbeddedDocsReview, SchedulerReview):
            for name in unittest.defaultTestLoader.getTestCaseNames(cls):
                if CONFIG.match in name:
                    suite.addTest(cls(name))
                    names.append(cls.__name__ + "." + name)
        if not names:
            parser.error("--match selected no tests")
        if not CONFIG.match and len(names) < 50:
            raise RuntimeError("review inventory lost its required adversarial coverage")
        provenance = {"compilerSha256": hashlib.sha256(CONFIG.compiler.read_bytes()).hexdigest(),
                      "binaries": {str(p.relative_to(CONFIG.artifacts)): hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in sorted(CONFIG.artifacts.glob("*/*/app"))}}
        (CONFIG.output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        (CONFIG.output / "inventory.json").write_text(json.dumps(names, indent=2) + "\n")
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        # Some cases build their own releases; include those binaries in final
        # provenance rather than recording only the inputs present at startup.
        provenance["binaries"] = {str(p.relative_to(CONFIG.artifacts)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in sorted(CONFIG.artifacts.glob("*/*/app"))}
        provenance["schedulerTypes"] = CONFIG.scheduler_types
        provenance["poolLeaseTimeoutMS"] = LAB.env.get("TESL_PG_POOL_LEASE_TIMEOUT_MS", "10000")
        (CONFIG.output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        (CONFIG.output / "result.json").write_text(json.dumps({"run": result.testsRun, "failures": [t.id() for t, _ in result.failures], "errors": [t.id() for t, _ in result.errors], "expectedFailures": [t.id() for t, _ in result.expectedFailures]}, indent=2) + "\n")
        raise SystemExit(0 if result.wasSuccessful() else 1)
    finally:
        LAB.close()


if __name__ == "__main__":
    main()

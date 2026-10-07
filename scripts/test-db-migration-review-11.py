#!/usr/bin/env python3
"""Review 11: boundary attacks on real compiler releases and private PostgreSQL.

Run in nix develop. --build builds the ordinary row/queue V1–V4 releases.
Every database test clones an idle template. Only fault injection uses the
installer; tested commands use their documented role. JSON records include
failures, skips, source revision and binary hashes, including lazily built inputs.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("review05", ROOT / "scripts/test-db-migration-review-05.py")
old = importlib.util.module_from_spec(spec)
spec.loader.exec_module(old)
LAB = CONFIG = None
require, literal = old.require, old.literal


class DatabaseCase(unittest.TestCase):
    template = "review_v2"
    family = "queue"

    def setUp(self):
        self.db = LAB.clone(self.template)
        self.addCleanup(lambda: LAB.sql("postgres", f"drop database {self.db} with (force)"))

    def snapshot(self):
        tables = ["tesl_schema_state", "tesl_schema_versions", "tesl_row_queue_conversion_staging",
                  "tesl_row_queue_target_staging", "tesl_row_queue_conversion_receipts",
                  "tesl_row_queue_conversion_attempts", "tesl_row_queue_retirements", "tesl_row_queue_restamps", "tesl_jobs"]
        return {table: LAB.sql(self.db, f"select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),'[]') from mail.{table} t") for table in tables}

    def refused(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("panic:", result.stderr)
        self.assertTrue(result.stderr.strip(), "refusal needs a diagnostic")

    def enqueue(self, version=1, identity="old", payload=None):
        if payload is None:
            payload = {"oldText": "retained"} if version == 1 else {"message": "retained", "priority": 7}
        LAB.sql(self.db, f"select mail.tesl_queue_enqueue({version},'Jobs','Delivery',{literal(identity)},{literal(json.dumps(payload))}::jsonb)", "review_request")

    def claim(self, version=1):
        return json.loads(LAB.sql(self.db, f"select row_to_json(c) from mail.tesl_queue_claim({version},'Jobs','pending','review11',60000) c", "review_request"))

    def convert(self):
        process, log = LAB.start(self.db, "v2")
        try:
            LAB.wait(lambda: LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_conversion_receipts") == "1", process)
        finally:
            LAB.stop(process, log)


class CatalogReview(DatabaseCase):
    pass


CATALOG = [
    ("selector_volatile", "alter function mail.tesl_row_queue_dispatch_sources() volatile"),
    ("selector_invoker", "alter function mail.tesl_row_queue_dispatch_sources() security invoker"),
    ("selector_search_path", "alter function mail.tesl_row_queue_dispatch_sources() set search_path=public"),
    ("selector_leakproof", "alter function mail.tesl_row_queue_dispatch_sources() leakproof"),
    ("selector_public_execute", "grant execute on function mail.tesl_row_queue_dispatch_sources() to public"),
    ("selector_extra_overload", "create function mail.tesl_row_queue_dispatch_sources(integer) returns text language sql as 'select ''forged'''; alter function mail.tesl_row_queue_dispatch_sources(integer) owner to review_owner"),
    ("fairness_index_reversed_keys", "drop index mail.tesl_row_queue_conversion_fair; create index tesl_row_queue_conversion_fair on mail.tesl_row_queue_conversion_receipts(attempt_seq,source_digest)"),
    ("fairness_index_partial", "drop index mail.tesl_row_queue_conversion_fair; create index tesl_row_queue_conversion_fair on mail.tesl_row_queue_conversion_receipts(source_digest,attempt_seq) where kind='converted'"),
    ("fairness_index_wrong_order", "drop index mail.tesl_row_queue_conversion_fair; create index tesl_row_queue_conversion_fair on mail.tesl_row_queue_conversion_receipts(source_digest,attempt_seq desc)"),
    ("status_invoker", "alter function mail.tesl_row_queue_status() security invoker"),
    ("status_grant_option", "grant execute on function mail.tesl_row_queue_status() to review_request with grant option"),
    ("staging_extra_trigger", "create function mail.review11_trigger() returns trigger language plpgsql as 'begin return new; end'; create trigger review11_attack before insert on mail.tesl_row_queue_conversion_staging for each row execute function mail.review11_trigger()"),
    ("attempts_rls", "alter table mail.tesl_row_queue_conversion_attempts enable row level security"),
    ("receipts_request_column_grant", "grant select(original) on mail.tesl_row_queue_conversion_receipts to review_request"),
    ("staging_worker_update_grant", "grant update on mail.tesl_row_queue_conversion_staging to review_worker"),
    ("target_owner_changed", "alter table mail.tesl_row_queue_target_staging owner to review_installer"),
]


def catalog_case(sql):
    def test(self):
        LAB.sql(self.db, sql)
        before = self.snapshot()
        self.refused(LAB.schema(self.db, "v2", "status", role="review_request"))
        self.assertEqual(self.snapshot(), before)
    return test


for number, (name, sql) in enumerate(CATALOG, 1):
    setattr(CatalogReview, f"test_{number:03}_{name}", catalog_case(sql))


class RoleReview(DatabaseCase):
    pass


DENIED = [
    ("request_selector", "review_request", "select * from mail.tesl_row_queue_dispatch_sources()"),
    ("request_receipt_bytes", "review_request", "select original from mail.tesl_row_queue_conversion_receipts"),
    ("worker_receipt_bytes", "review_worker", "select original from mail.tesl_row_queue_conversion_receipts"),
    ("request_attempt_bytes", "review_request", "select original from mail.tesl_row_queue_conversion_attempts"),
    ("worker_attempt_bytes", "review_worker", "select original from mail.tesl_row_queue_conversion_attempts"),
    ("request_restamp_audit", "review_request", "select * from mail.tesl_row_queue_restamps"),
    ("worker_restamp_delete", "review_worker", "delete from mail.tesl_row_queue_restamps"),
    ("request_staging_delete", "review_request", "delete from mail.tesl_row_queue_conversion_staging"),
    ("worker_target_delete", "review_worker", "delete from mail.tesl_row_queue_target_staging"),
    ("request_owner_role", "review_request", "set role review_owner"),
    ("worker_owner_role", "review_worker", "set role review_owner"),
    ("request_worker_role", "review_request", "set role review_worker"),
]


def denied_case(role, sql):
    def test(self):
        before = self.snapshot()
        self.refused(LAB.sql(self.db, sql, role, ok=False))
        self.assertEqual(self.snapshot(), before)
    return test


for number, (name, role, sql) in enumerate(DENIED, 17):
    setattr(RoleReview, f"test_{number:03}_{name}", denied_case(role, sql))


class StagingReview(DatabaseCase):
    template = "review11_staged"
    family = "fair-many-33"

    @classmethod
    def setUpClass(cls):
        family = CONFIG.artifacts / cls.family
        stamp = family / "compiler.sha256"
        digest = hashlib.sha256(CONFIG.compiler.read_bytes()).hexdigest()
        if not stamp.exists() or stamp.read_text().strip() != digest:
            LAB.build_fairness_payloads(cls.family, 32)
        LAB.sql("postgres", f"create database {cls.template}")
        LAB.sql("postgres", f"grant create on database {cls.template} to review_owner")
        LAB.sql(cls.template, "grant create on schema public to review_owner")
        require(LAB.install(cls.template, "v1", cls.family))
        LAB.stop(*LAB.start(cls.template, "v1", cls.family))
        require(LAB.install(cls.template, "v2", cls.family))

    def install(self, role="review_installer"):
        return LAB.schema(self.db, "v2", "install", "--worker", "review_worker", "--request", "review_request", family=self.family, role=role)

    def test_029_second_batch_failure_retains_only_first_committed_group(self):
        LAB.sql(self.db, "delete from mail.tesl_row_queue_target_staging; delete from mail.tesl_row_queue_conversion_staging where job_type<>'Other031'; update mail.tesl_row_queue_conversion_staging set fence_ns=fence_ns+1")
        self.refused(self.install())
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_conversion_staging where fence_ns=(select fence_ns from mail.tesl_schema_meta)"), "32")
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_target_staging"), "0")
        self.assertEqual(LAB.sql(self.db, "select current||','||min_version||','||compat_floor from mail.tesl_schema_state"), "1,1,1")
        # Fault repair by observer restores exact original fence; installer resumes.
        LAB.sql(self.db, "update mail.tesl_row_queue_conversion_staging set fence_ns=(select fence_ns from mail.tesl_schema_meta) where job_type='Other031'")
        require(self.install())
        before = self.snapshot()
        require(self.install())
        self.assertEqual(self.snapshot(), before)

    def test_030_worker_cannot_install_staging_batch(self):
        before = self.snapshot()
        self.refused(self.install("review_worker"))
        self.assertEqual(self.snapshot(), before)

    def test_031_request_cannot_install_staging_batch(self):
        before = self.snapshot()
        self.refused(self.install("review_request"))
        self.assertEqual(self.snapshot(), before)


def staging_case(field, value):
    def test(self):
        LAB.sql(self.db, "delete from mail.tesl_row_queue_target_staging; delete from mail.tesl_row_queue_conversion_staging where job_type='Delivery'")
        LAB.sql(self.db, f"update mail.tesl_row_queue_conversion_staging set {field}={value} where job_type='Other000'")
        before = self.snapshot()
        self.refused(self.install())
        self.assertEqual(self.snapshot(), before)
    return test


for number, (field, value) in enumerate([
    ("database_uuid", "gen_random_uuid()"),
    ("inventory_hash", "repeat('a',64)"),
    ("expansion_hash", "repeat('b',64)"),
    ("old_contract", "old_contract||'x'::bytea"),
    ("new_contract", "new_contract||'x'::bytea"),
], 32):
    setattr(StagingReview, f"test_{number:03}_late_member_{field}_mismatch_is_atomic", staging_case(field, value))


class LifecycleReview(DatabaseCase):
    def test_037_enqueue_rollback_leaves_no_job_or_receipt(self):
        before = self.snapshot()
        LAB.sql(self.db, "begin; select mail.tesl_queue_enqueue(1,'Jobs','Delivery','rolled','{\"oldText\":\"rolled\"}'); rollback", "review_request")
        self.assertEqual(self.snapshot(), before)

    def test_038_claim_rollback_restores_attempt_ownership(self):
        self.enqueue()
        before = self.snapshot()
        LAB.sql(self.db, "begin; select * from mail.tesl_queue_claim(1,'Jobs','pending','rolled',60000); rollback", "review_request")
        self.assertEqual(self.snapshot(), before)

    def test_039_complete_rollback_preserves_live_claim(self):
        self.enqueue()
        claim = self.claim()
        before = self.snapshot()
        LAB.sql(self.db, f"begin; select mail.tesl_queue_complete(1,'Jobs','old',{literal(claim['token'])},{claim['attempt_seq']}); rollback", "review_request")
        self.assertEqual(self.snapshot(), before)

    def test_040_requeue_cannot_reinterpret_changed_old_contract(self):
        self.enqueue()
        LAB.sql(self.db, "update mail.tesl_jobs set status='dead',dead_reason='attempts-exhausted',attempts=7")
        before = self.snapshot()
        self.assertEqual(LAB.sql(self.db, "select mail.tesl_queue_requeue(2,'Jobs','old')", "review_request"), "f")
        self.assertEqual(self.snapshot(), before)

    def test_041_current_claim_cannot_consume_incompatible_old_payload(self):
        self.enqueue()
        before = self.snapshot()
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_queue_claim(2,'Jobs','pending','new',60000)", "review_request"), "0")
        self.assertEqual(self.snapshot(), before)

    def test_042_old_claim_cannot_consume_future_payload(self):
        self.enqueue(2, "new")
        before = self.snapshot()
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_queue_claim(1,'Jobs','pending','old',60000)", "review_request"), "0")
        self.assertEqual(self.snapshot(), before)

    def test_043_receipt_survives_real_completion_and_replay(self):
        self.enqueue()
        self.convert()
        receipt = LAB.sql(self.db, "select row_to_json(r)::text from mail.tesl_row_queue_conversion_receipts r")
        claim = self.claim(2)
        self.assertEqual(LAB.sql(self.db, f"select mail.tesl_queue_complete(2,'Jobs','old',{literal(claim['token'])},{claim['attempt_seq']})", "review_request"), "t")
        require(LAB.install(self.db, "v2"))
        self.assertEqual(LAB.sql(self.db, "select row_to_json(r)::text from mail.tesl_row_queue_conversion_receipts r"), receipt)
        self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_jobs"), "0")

    def quarantine_current(self):
        self.enqueue(2, "invalid-current", {"message": 42, "priority": 7})
        claim = self.claim(2)
        self.assertEqual(LAB.sql(self.db, f"select mail.tesl_queue_quarantine(2,'Jobs','invalid-current',{literal(claim['token'])},{claim['attempt_seq']})", "review_request"), "t")

    def test_044_current_invalid_job_cannot_hide_old_backlog_status(self):
        self.quarantine_current()
        self.enqueue()
        before = self.snapshot()
        summary = json.loads(require(LAB.schema(self.db, "v2", "status", role="review_request")))["queues"]
        self.assertEqual(summary["oldPayloads"], 1)
        self.assertEqual(summary["invalid"], 1, "current operational quarantine must remain visible")
        blockers = {item["code"]: item["count"] for item in summary["blockers"]}
        self.assertEqual(blockers.get("QUEUE_OLD_PAYLOADS"), 1, summary)
        self.assertEqual(self.snapshot(), before)

    def test_045_current_invalid_status_agrees_with_retirement(self):
        self.quarantine_current()
        summary = json.loads(require(LAB.schema(self.db, "v2", "status", role="review_request")))["queues"]
        self.assertEqual(summary["invalid"], 1)
        require(LAB.schema(self.db, "v2", "contract", "V2"))
        self.assertFalse(any(b["code"] == "QUEUE_PAYLOAD_INVALID" for b in summary["blockers"]), summary)

    def test_046_snapshot_enqueue_refuses_without_mutation(self):
        before = self.snapshot()
        self.refused(LAB.sql(self.db, "begin isolation level repeatable read; select mail.tesl_queue_enqueue(1,'Jobs','Delivery','wrong-isolation','{}'); commit", "review_request", ok=False))
        self.assertEqual(self.snapshot(), before)

    def test_047_serializable_claim_refuses_without_mutation(self):
        self.enqueue()
        before = self.snapshot()
        self.refused(LAB.sql(self.db, "begin isolation level serializable; select * from mail.tesl_queue_claim(1,'Jobs','pending','wrong-isolation',60000); commit", "review_request", ok=False))
        self.assertEqual(self.snapshot(), before)

    def test_048_statement_cancelled_enqueue_is_atomic(self):
        before = self.snapshot()
        # Cancellation after the protected insert, inside the same transaction.
        self.refused(LAB.sql(self.db, "begin; set local statement_timeout='50ms'; select mail.tesl_queue_enqueue(1,'Jobs','Delivery','cancelled','{}'); select pg_sleep(1); commit", "review_request", ok=False))
        self.assertEqual(self.snapshot(), before)


class SourceReview(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="source-", dir=CONFIG.output)
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name) / "source"
        shutil.copytree(CONFIG.artifacts / "queue/v2/source", self.source)

    def check_mutation(self, file, before, after):
        path = self.source / file
        text = path.read_text()
        self.assertIn(before, text)
        path.write_text(text.replace(before, after, 1))
        context = json.loads(old.run([CONFIG.compiler, "agent-context", self.source / "app.tesl"], env=LAB.env).stdout)
        self.assertFalse(context["ok"], context)
        self.assertTrue(context["diagnostics"], context)
        self.assertFalse(any(d["code"] == "E000" for d in context["diagnostics"]), context)


SOURCE_ATTACKS = [
    ("fixture_callback_swap", "migrations/mail/v2.tesl", "fixtures: [Schema.Mail.Migrate.Convert2.oldJob]", "fixtures: [Schema.Mail.Migrate.Convert2.convert]"),
    ("fixture_duplicate", "migrations/mail/v2.tesl", "fixtures: [Schema.Mail.Migrate.Convert2.oldJob]", "fixtures: [Schema.Mail.Migrate.Convert2.oldJob, Schema.Mail.Migrate.Convert2.oldJob]"),
    ("fixture_current_nominal", "migrations/mail/convert2.tesl", 'fn oldJob() -> Schema.Mail.V1.Delivery = Schema.Mail.V1.Delivery { text: "kept" }', 'fn oldJob() -> Schema.Mail.VCurrent.Delivery = Schema.Mail.VCurrent.Delivery { body: "kept", priority: 7 }'),
    ("fixture_parameter", "migrations/mail/convert2.tesl", "fn oldJob()", "fn oldJob(ignored: String)"),
    ("fixture_private", "migrations/mail/convert2.tesl", "convert, repair, oldJob, rejectedJob", "convert, repair, rejectedJob"),
    ("callback_private", "migrations/mail/convert2.tesl", "convert, repair, oldJob, rejectedJob", "repair, oldJob, rejectedJob"),
    ("callback_extra_parameter", "migrations/mail/convert2.tesl", "fn convert(old: Schema.Mail.V1.Delivery)", "fn convert(old: Schema.Mail.V1.Delivery, extra: Int)"),
    ("unreachable_helper_illtyped", "migrations/mail/convert2.tesl", 'import Tesl.Prelude exposing [String, Int, Bool(..)]', 'import Tesl.Prelude exposing [String, Int, Bool(..)]\nfn unreachable() -> Int = "wrong"'),
    ("fixture_frozen_codec_substitution", "schema/mail/v1.tesl", '"oldText"', '"oldTextRenamed"'),
    ("historical_record_extra_field", "schema/mail/v1.tesl", "text: String", "text: String, extra: String"),
    ("missing_job_decision", "migrations/mail/v2.tesl", "jobs: { Delivery: Migrate Schema.Mail.Migrate.Convert2.convert }", "jobs: {}"),
    ("current_missing_decoder", "schema/mail/v-current.tesl", 'fromJson [ { body <- "message" with_codec stringCodec, priority <- "priority" with_codec intCodec } ]', "fromJson forbidden"),
]


def source_case(file, before, after):
    return lambda self: self.check_mutation(file, before, after)


for number, (name, file, before, after) in enumerate(SOURCE_ATTACKS, 49):
    setattr(SourceReview, f"test_{number:03}_{name}", source_case(file, before, after))


class RowSourceReview(unittest.TestCase):
    check_mutation = SourceReview.check_mutation

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="row-source-", dir=CONFIG.output)
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name) / "source"
        version = getattr(getattr(self, self._testMethodName), "version")
        shutil.copytree(CONFIG.artifacts / "row" / f"v{version}" / "source", self.source)


def row_positive(version):
    def test(self):
        result = old.run([CONFIG.compiler, "agent-context", self.source / "app.tesl"], env=LAB.env)
        context = json.loads(result.stdout)
        self.assertTrue(context["ok"], context)
        self.assertEqual(result.returncode, 0)
    test.version = version
    return test


for number, version in enumerate((2, 3, 4), 61):
    setattr(RowSourceReview, f"test_{number:03}_row_v{version}_positive_control", row_positive(version))


ROW_ATTACKS = [
    (2, "missing_writeback", "migrations/notes/v2.tesl", ", WriteBack metadata metadata backward", ""),
    (2, "changed_primary_key", "migrations/notes/v2.tesl", "id: old.id", 'id: "replacement"'),
    (2, "rename_wrong_destination", "migrations/notes/v2.tesl", "Rename author owner", "Rename author title"),
    (3, "missing_legacy_value", "migrations/notes/v3.tesl", 'Legacy memo "legacy-default", ', ""),
    (3, "wrong_reverse_field_type", "migrations/notes/v3.tesl", "text: row.metadata.body", "text: row.metadata.revision"),
    (4, "missing_nominal_same", "migrations/notes/v4.tesl", "same: [Same Schema.Notes.V3.Metadata Schema.Notes.VCurrent.Metadata]", "same: []"),
    (4, "revalidate_substitutes_value", "migrations/notes/v4.tesl", "tryTitle old.title", 'tryTitle "replacement"'),
    (4, "raw_unproven_title", "migrations/notes/v4.tesl", "title: title", "title: old.title"),
    (4, "missing_result_field", "migrations/notes/v4.tesl", "metadata: old.metadata", ""),
    (4, "contract_wrong_predecessor", "migrations/notes/v4-contract.tesl", "of: Schema.Notes.Migrate.V4", "of: Schema.Notes.Migrate.V3"),
]
for number, (version, name, file, before, after) in enumerate(ROW_ATTACKS, 64):
    case = source_case(file, before, after)
    case.version = version
    setattr(RowSourceReview, f"test_{number:03}_row_{name}", case)


class ExecutionReview(DatabaseCase):
    template = "review11_poison_v1"
    family = "fair-poison"

    @classmethod
    def setUpClass(cls):
        family = CONFIG.artifacts / cls.family
        stamp = family / "compiler.sha256"
        digest = hashlib.sha256(CONFIG.compiler.read_bytes()).hexdigest()
        if not stamp.exists() or stamp.read_text().strip() != digest:
            LAB.build_fairness_payloads(cls.family)
        source = sorted(family.glob("source-*"), key=lambda path: path.stat().st_mtime_ns)[-1]
        target = Path(tempfile.mkdtemp(prefix="poison-", dir=family))
        shutil.copytree(source, target / "source")
        helper = target / "source/migrations/mail/convert2.tesl"
        text = helper.read_text()
        expression = "Row (Schema.Mail.VCurrent.Delivery { body: old.text, priority: 7 })"
        if expression not in text:
            raise AssertionError("poison fixture lost its positive converter")
        helper.write_text(text.replace(expression, 'if old.text == "poison" then\n      convert old\n    else\n      ' + expression, 1))
        require(old.run([CONFIG.compiler, "agent-context", helper], env=LAB.env))
        require(old.run([CONFIG.compiler, "--backend", "go", target / "source/app.tesl", "--out", target / "go"], env=LAB.env))
        require(old.run(["go", "test", "-race", "-p", "1", "./..."], cwd=target / "go", env=LAB.env, timeout=180))
        require(old.run(["go", "build", "-race", "-o", target / "app", "./cmd/app"], cwd=target / "go", env=LAB.env))
        cls.release = target.name
        LAB.sql("postgres", f"create database {cls.template}")
        LAB.sql("postgres", f"grant create on database {cls.template} to review_owner")
        LAB.sql(cls.template, "grant create on schema public to review_owner")
        require(LAB.install(cls.template, "v1", cls.family))
        LAB.stop(*LAB.start(cls.template, "v1", cls.family))

    def test_074_poisoned_type_stops_peer_without_publishing(self):
        self.enqueue(payload={"oldText": "poison"})
        LAB.sql(self.db, "select mail.tesl_queue_enqueue(1,'Jobs','Other','healthy','{\"oldText\":\"healthy\"}')", "review_request")
        require(LAB.install(self.db, self.release, self.family))
        for _ in range(2):
            result = LAB.schema(self.db, self.release, "worker", family=self.family)
            self.refused(result)
            self.assertIn("migration execution stopped", result.stderr)
            self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_jobs where schema_version=1 and status='pending'"), "2")
            self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_conversion_attempts"), "0")
            self.assertEqual(LAB.sql(self.db, "select count(*) from mail.tesl_row_queue_conversion_receipts"), "0")
        status = json.loads(require(LAB.schema(self.db, self.release, "status", family=self.family, role="review_request")))["queues"]
        self.assertEqual({item["code"] for item in status["blockers"]}, {"QUEUE_OLD_PAYLOADS"})


def main():
    global CONFIG, LAB
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, default=ROOT / "compiler/_build/default/bin/main.exe")
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--match", default="")
    CONFIG = parser.parse_args()
    CONFIG.artifacts, CONFIG.output = CONFIG.artifacts.resolve(), CONFIG.output.resolve()
    CONFIG.output.mkdir(parents=True, exist_ok=True)
    old.CONFIG = CONFIG
    LAB = old.Lab()
    old.LAB = LAB
    try:
        if CONFIG.build:
            for family, example in (("queue", "queue-three-upgrades"), ("row", "db-three-upgrades")):
                require(old.run(["python3", ROOT / "example" / example / "run.py", "--compiler", CONFIG.compiler, "--output", CONFIG.artifacts / family, "--build-only"], timeout=1200))
        LAB.prepare()
        suite = unittest.TestSuite()
        names = []
        for cls in (CatalogReview, RoleReview, StagingReview, LifecycleReview, SourceReview, RowSourceReview, ExecutionReview):
            for name in unittest.defaultTestLoader.getTestCaseNames(cls):
                if CONFIG.match in name:
                    suite.addTest(cls(name))
                    names.append(cls.__name__ + "." + name)
        if not names:
            parser.error("--match selected no cases")
        (CONFIG.output / "inventory.json").write_text(json.dumps(names, indent=2)+"\n")
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        provenance = {"git": require(old.run(["git", "rev-parse", "HEAD"], cwd=ROOT)),
                      "compilerSha256": hashlib.sha256(CONFIG.compiler.read_bytes()).hexdigest(),
                      "binaries": {str(p.relative_to(CONFIG.artifacts)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(CONFIG.artifacts.glob("*/*/app"))}}
        (CONFIG.output / "provenance.json").write_text(json.dumps(provenance, indent=2)+"\n")
        (CONFIG.output / "result.json").write_text(json.dumps({"run": result.testsRun, "failures": [t.id() for t, _ in result.failures], "errors": [t.id() for t, _ in result.errors], "skipped": result.skipped, "expectedFailures": [t.id() for t, _ in result.expectedFailures]}, indent=2)+"\n")
        raise SystemExit(0 if result.wasSuccessful() else 1)
    finally:
        LAB.close()


if __name__ == "__main__":
    main()

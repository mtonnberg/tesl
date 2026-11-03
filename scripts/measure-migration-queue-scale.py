#!/usr/bin/env python3
"""Measure a public multi-type queue rollout without hiding setup in a progress SLA.

Reuses the review fixture builder, exact compiler, application roles and private
PostgreSQL. Enqueue setup uses bounded protected SQL calls; no raw job inserts.
The existing 25-second progress target is reported separately from the observation
window. A completed slow observation is not a passing latency acceptance test.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("review", ROOT / "scripts/test-db-migration-review-05.py")
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, default=ROOT / "compiler/_build/default/bin/main.exe")
    parser.add_argument("--types", type=int, default=257)
    parser.add_argument("--backlog", type=int, default=1024)
    parser.add_argument("--observe-seconds", type=int, default=600)
    parser.add_argument("--release-build", action="store_true", help="measure ordinary Go build without race instrumentation")
    parser.add_argument("--function-profile", action="store_true", help="record PostgreSQL function costs in this private test cluster")
    args = parser.parse_args()
    if not 3 <= args.types <= 257 or not 1 <= args.backlog <= 4096 or not 25 <= args.observe_seconds <= 1200:
        parser.error("types must be 3–257, backlog 1–4096, observation 25–1200 seconds")
    args.artifacts, args.output, args.compiler = args.artifacts.resolve(), args.output.resolve(), args.compiler.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    review.CONFIG = args
    lab = review.Lab()
    family = f"fair-many-{args.types}" + ("-release" if args.release_build else "")
    db = "review_scale"
    result = {"types": args.types, "backlog": args.backlog, "progressTargetSeconds": 25,
              "observationSeconds": args.observe_seconds, "raceInstrumented": not args.release_build,
              "commandBudgetMS": os.environ.get("TESL_PG_POOL_LEASE_TIMEOUT_MS", "10000")}
    worker = None
    try:
        started = time.monotonic()
        stamp = args.artifacts / family / "compiler.sha256"
        compiler_hash = hashlib.sha256(args.compiler.read_bytes()).hexdigest()
        if not stamp.exists() or stamp.read_text().strip() != compiler_hash:
            lab.build_fairness_payloads(family, args.types-1, race=not args.release_build)
        result["buildSeconds"] = time.monotonic()-started
        result["compilerSha256"] = compiler_hash
        result["binaries"] = {v: hashlib.sha256((args.artifacts / family / v / "app").read_bytes()).hexdigest() for v in ("v1", "v2")}
        lab.prepare()
        if args.function_profile:
            lab.sql("postgres", "alter system set track_functions='all'")
            lab.sql("postgres", "select pg_reload_conf()")
        lab.sql("postgres", f"create database {db}")
        lab.sql("postgres", f"grant create on database {db} to review_owner")
        lab.sql(db, "grant create on schema public to review_owner")
        review.require(lab.install(db, "v1", family))
        lab.stop(*lab.start(db, "v1", family))
        started = time.monotonic()
        review.require(lab.install(db, "v2", family))
        result["installSeconds"] = time.monotonic()-started
        started = time.monotonic()
        # Fixed-size transactions exercise the same protected enqueue operation.
        # Keep its 90s command bound while measuring the total setup explicitly.
        for start in range(0, args.backlog, 32):
            lab.sql(db, f"select mail.tesl_queue_enqueue(1,'Jobs','Delivery','busy-'||n::text,'{{\"oldText\":\"busy\"}}') from generate_series({start},{min(start+31,args.backlog-1)}) n", "review_request")
        for start in range(0, args.types-1, 32):
            lab.sql(db, f"select mail.tesl_queue_enqueue(1,'Jobs','Other'||lpad(n::text,3,'0'),'rare-'||n::text,'{{\"oldText\":\"rare\"}}') from generate_series({start},{min(start+31,args.types-2)}) n", "review_request")
        result["enqueueSeconds"] = time.monotonic()-started
        if args.function_profile:
            lab.sql(db, "select pg_stat_reset()")
        started = time.monotonic()
        worker = lab.start(db, "v2", family)
        result["workerStartupSeconds"] = time.monotonic()-started
        started = time.monotonic()
        samples = []
        while True:
            sample = json.loads(lab.sql(db, "select json_build_object('convertedTypes',count(distinct job_type) filter(where schema_version=2),'remainingHead',count(*) filter(where job_type='Delivery' and schema_version=1),'oldJobs',count(*) filter(where schema_version=1)) from mail.tesl_jobs"))
            sample["seconds"] = time.monotonic()-started
            samples.append(sample)
            if sample["convertedTypes"] == args.types or sample["seconds"] >= args.observe_seconds or worker[0].poll() is not None:
                break
            time.sleep(.5)
        result["samples"] = samples
        result["allTypesProgressed"] = sample["convertedTypes"] == args.types
        result["progressSeconds"] = sample["seconds"]
        result["meets25SecondTarget"] = result["allTypesProgressed"] and sample["seconds"] <= 25
        result["headStillPending"] = sample["remainingHead"] > 0
        result["finalProgress"] = sample
        result["workerExit"] = worker[0].poll()
        result["payloadsCorrect"] = lab.sql(db, "select coalesce(bool_and(case when schema_version=1 then payload=jsonb_build_object('oldText',case when job_type='Delivery' then 'busy' else 'rare' end) else payload=jsonb_build_object('message',case when job_type='Delivery' then 'busy' else 'rare' end,'priority',case when job_type='Delivery' then 7 else 11 end) end),false) from mail.tesl_jobs") == "t"
        result["admission"] = lab.sql(db, "select current||','||min_version||','||compat_floor from mail.tesl_schema_state")
        if not result["payloadsCorrect"] or result["admission"] != "2,1,1":
            raise RuntimeError("scale workload lost payload or admission invariants")
        if args.function_profile:
            lab.stop(*worker)
            worker = None
            time.sleep(1)
            result["functionProfile"] = json.loads(lab.sql(db, "select coalesce(json_agg(x),'[]') from (select funcname,calls,total_time,self_time from pg_stat_user_functions where schemaname='mail' order by self_time desc) x"))
        print(json.dumps({k:v for k,v in result.items() if k != "samples"}, indent=2), flush=True)
    finally:
        if worker:
            lab.stop(*worker)
        (args.output / "measurement.json").write_text(json.dumps(result, indent=2)+"\n")
        lab.close()


if __name__ == "__main__":
    main()

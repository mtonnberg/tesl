#!/usr/bin/env python3
"""Measure real old/new requests, backfill, restart, index work and Contract.

Owns private PostgreSQL data and uses fresh ordinary compiler-generated programs.
The correctness-smoke mode makes no timing/SLA acceptance claim. Performance
mode records the original <=1% read / <=5% write p99 budgets without relaxing
them; shared-host measurements cannot replace the specified pinned reference.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

from migration_rollout_workload import (Cluster, Load, Observer, SQL, build_artifacts,
    command, compare_budget, digest, http_request, resource_estimate, summarize, validate_row)

ROOT = Path(__file__).resolve().parents[1]


class ObservationBudgetExceeded(Exception):
    pass


class ResourceLimitExceeded(Exception):
    pass


def backfill_rate(progress):
    samples = [p for p in progress if p['rowsDone'] > 0]
    if len(samples) < 2 or samples[-1]['at'] <= samples[0]['at']:
        return {'status': 'insufficient-evidence'}
    rows = samples[-1]['rowsDone'] - samples[0]['rowsDone']
    seconds = samples[-1]['at'] - samples[0]['at']
    return {'status': 'observed', 'rows': rows, 'seconds': seconds,
            'rowsPerSecond': rows / seconds,
            'interpretation': 'committed progress after startup/restart; sampled endpoints, not completed migration throughput'}


def interrupted(number, frame):
    # Unwind through cleanup before an outer CI timeout starts another workload.
    raise KeyboardInterrupt(f'interrupted by {signal.Signals(number).name}')


def seed(cluster, database, rows, version, namespace='notes'):
    owner = 'author' if version == 1 else 'owner'
    metadata = "jsonb_build_object('oldText',identity)" if version == 1 else "jsonb_build_object('message',identity,'detail','writer-v2')"
    # Fixture setup happens before timed requests, through valid source rows.
    # Never rewrite migration generation markers, receipts or admission floors.
    extra_column, extra_value = (',active', ',false') if namespace == 'lookup' else ('', '')
    for first in range(0, rows, 100000):
        if shutil.disk_usage(cluster.output).free < 2 << 30:
            raise ResourceLimitExceeded('free disk reached the reserved 2GiB during fixture seeding')
        last = min(rows - 1, first + 99999)
        cluster.sql(database, f"insert into {namespace}.notes(id,metadata,{owner},memo,title{extra_column}) select identity,{metadata},'original-owner','retained-memo',identity{extra_value} from (select 'r'||lpad(n::text,12,'0') identity from generate_series({first},{last}) n) source", timeout=1800)


def phase_summary(loads, phase=None):
    observations = [o for load in loads for o in load['observations'] if not o['warmup'] and (phase is None or o['phase'] == phase)]
    return {operation: summarize([o for o in observations if o['operation'] == operation])
            for operation in sorted({o['operation'] for o in observations})}


def run_case(args, manifest, cluster, rows, output):
    output.mkdir()
    result = {'rows': rows, 'status': 'incomplete', 'loads': [], 'events': [], 'progress': [],
              'resources': {}, 'correctnessPassed': False}
    active = []
    observer = None
    blocker = None
    phase = 'setup'
    programs = {name: Path(p['binary']) for name, p in manifest['programs'].items()}
    database = f'rollout_{rows}'
    controls = [f'plain1_{rows}', f'plain2_{rows}']
    phase_seconds = args.seconds
    batch = min(args.batch, max(1, rows // 10))
    result['batchSize'] = batch

    def event(name, **extra):
        result['events'].append({'name': name, 'at': time.time(), **extra})

    def stop_loads():
        while active:
            data = active.pop().stop()
            result['loads'].append(data)
            if data['failures']:
                raise RuntimeError(f'load correctness/request failure: {data["failures"][:3]}')

    def measured_load(port, version, clients, label, offset):
        load = Load(port, version, clients, label, lambda: phase, offset=offset, transaction=args.transaction)
        active.append(load)
        return load

    try:
        for name in [database, *controls]:
            cluster.sql('postgres', f'create database {name}')
            cluster.sql('postgres', f'grant create on database {name} to demo_owner,demo_request')
            cluster.sql(name, 'grant create on schema public to demo_owner,demo_request')
        cluster.schema(programs['v1'], database, 'bench_installer', 'install', '--worker', 'demo_worker', '--request', 'demo_request')
        worker, _ = cluster.start(programs['v1'], database, True, batch)
        old, old_port = cluster.start(programs['v1'], database)
        seed(cluster, database, rows, 1)
        cluster.schema(programs['index1'], database, 'bench_installer', 'install', '--worker', 'demo_worker', '--request', 'demo_request')
        index_worker, _ = cluster.start(programs['index1'], database, True)
        seed(cluster, database, rows, 1, 'lookup')
        cluster.stop(index_worker)
        control_processes = []
        control_ports = []
        for version, name in enumerate(controls, 1):
            process, port = cluster.start(programs[f'plain{version}'], name)
            control_processes.append(process)
            control_ports.append(port)
            seed(cluster, name, rows, version)
        physical = json.loads(cluster.sql(database, "select json_build_object('bytesPerRow',pg_total_relation_size('notes.notes')::numeric/(select count(*) from notes.notes),'tableBytes',pg_total_relation_size('notes.notes'),'databaseBytes',pg_database_size(current_database()))"))
        result['resources'].update(physical)
        result['resources']['freeAfterSeed'] = shutil.disk_usage(output).free
        observer = Observer(cluster, database, output, args.lock_sample_seconds)
        event('seed-complete')

        for clients in args.clients:
            phase = f'control-{clients}'
            for version, port in enumerate(control_ports, 1):
                measured_load(port, version, clients, f'control-v{version}-c{clients}', version * 100)
            time.sleep(phase_seconds)
            stop_loads()
        for process in control_processes:
            cluster.stop(process)

        phase = 'steady-migration-v1'
        measured_load(old_port, 1, max(args.clients), 'steady-v1', 100)
        time.sleep(phase_seconds)
        stop_loads()
        cluster.stop(worker)
        phase = 'overlap-starting'
        measured_load(old_port, 1, max(args.clients), 'overlap-v1', 100)
        started = time.monotonic()
        event('rollout-start')
        if args.correctness_smoke:
            blocker = SQL(dict(cluster.env, PGDATABASE=database, PGUSER='demo_request'), output / 'index-overlap-writer.log')
            blocker.execute("begin;update lookup.notes set title=title where id='r000000000000'")
            event('smoke-only-index-writer-held')
        index_started = time.monotonic()
        index_worker, _ = cluster.start(programs['index2'], database, True, wait=False)
        worker, _ = cluster.start(programs['v2'], database, True, batch)
        event('new-worker-ready', seconds=time.monotonic() - started)
        # Capture one committed provisional batch before killing the real
        # process. Do not mutate its lease, marker or cursor to force recovery.
        restart_deadline = time.monotonic() + 15
        restarted = False
        while time.monotonic() < restart_deadline:
            ready = json.loads(cluster.sql(database, "select json_build_object('rowsDone',coalesce(sum(rows_done),0),'done',coalesce(bool_and(state in ('provisional','final')),false)) from notes.tesl_schema_backfill_shards where version=2"))
            if ready['rowsDone'] > 0:
                event('worker-killed', progress=ready)
                cluster.stop(worker, kill=True)
                worker, _ = cluster.start(programs['v2'], database, True, batch)
                event('worker-restarted', seconds=time.monotonic() - started, initialPassAlreadyExhausted=ready['done'])
                restarted = True
                break
            time.sleep(.025)
        if not restarted:
            raise RuntimeError('could not observe committed work for the worker restart witness')
        new, new_port = cluster.start(programs['v2'], database)
        event('new-request-ready', seconds=time.monotonic() - started)
        measured_load(new_port, 2, max(args.clients), 'overlap-v2', 200)
        if blocker:
            blocker.execute('commit')
            blocker.close()
            blocker = None
            event('smoke-only-index-writer-released', seconds=time.monotonic() - index_started)
        result['sqlProfileBeforeOverlap'] = json.loads(cluster.sql(database, "select coalesce(json_agg(row),'[]') from (select funcname,calls,total_time,self_time from pg_stat_user_functions where schemaname='notes' order by self_time desc) row"))
        phase = 'overlap-backfill'
        all_done_at = None
        while time.monotonic() - started < args.max_rollout_seconds:
            progress = json.loads(cluster.sql(database, "select json_build_object('at',extract(epoch from clock_timestamp()),'rowsDone',coalesce(sum(rows_done),0),'done',coalesce(bool_and(state in ('provisional','final')),false),'shards',count(*),'lastPk',max(last_pk::text)) from notes.tesl_schema_backfill_shards where version=2"))
            result['progress'].append(progress)
            if shutil.disk_usage(output).free < 2 << 30:
                raise ResourceLimitExceeded('free disk reached the reserved 2GiB during rollout')
            if progress['done']:
                all_done_at = time.monotonic()
                phase = 'overlap-after-backfill'
                break
            if worker.poll() is not None:
                raise RuntimeError('worker exited during healthy backfill')
            time.sleep(.2)
        if all_done_at is None:
            raise ObservationBudgetExceeded('rollout observation budget expired before backfill completed')
        result['backfillSeconds'] = all_done_at - started
        result['backfillRowsPerSecond'] = rows / result['backfillSeconds']
        result['steadyBackfill'] = backfill_rate(result['progress'])
        result['workerRestartedDuringBackfill'] = restarted
        time.sleep(phase_seconds)
        stop_loads()
        result['sqlProfileAfterOverlap'] = json.loads(cluster.sql(database, "select coalesce(json_agg(row),'[]') from (select funcname,calls,total_time,self_time from pg_stat_user_functions where schemaname='notes' order by self_time desc) row"))

        # Rejected conversion must not publish Contract or change either floor.
        phase = 'rejection-repair'
        reject_key = 'r000000000000'
        if http_request(old_port, 'PUT', f'/row/{reject_key}/blocked')[0] != 'blocked':
            raise RuntimeError('could not create rejected old-generation value')
        before = cluster.sql(database, 'select current,min_version,compat_floor from notes.tesl_schema_state')
        rejected = cluster.schema(programs['v2'], database, 'demo_worker', 'contract', 'V2', check=False, timeout=120)
        if rejected.returncode == 0 or not any(s in (rejected.stdout + rejected.stderr).lower() for s in ('reject', 'quarantin')):
            raise RuntimeError('Contract did not specifically refuse a rejected row')
        if cluster.sql(database, 'select current,min_version,compat_floor from notes.tesl_schema_state') != before:
            raise RuntimeError('rejected Contract changed admission floor')
        event('rejected-contract-refused', output=(rejected.stdout + rejected.stderr)[-2000:])
        http_request(old_port, 'PUT', f'/row/{reject_key}/repaired')
        if worker.poll() is not None:
            cluster.stop(worker)
            worker, _ = cluster.start(programs['v2'], database, True, batch)
            event('rejected-worker-restarted')
        deadline = time.monotonic() + 30
        while True:
            try:
                validate_row(http_request(new_port, 'GET', f'/row/{reject_key}')[0], reject_key, 2, 'repaired')
                break
            except RuntimeError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(.1)
        event('rejection-repaired-through-old-writer')
        cluster.stop(old)
        phase = 'contract'
        measured_load(new_port, 2, max(args.clients), 'contract-v2', 300)
        contract_started = time.monotonic()
        contracted = cluster.schema(programs['v2'], database, 'demo_worker', 'contract', 'V2', timeout=args.max_rollout_seconds)
        result['contractSeconds'] = time.monotonic() - contract_started
        result['contractResult'] = json.loads(contracted.stdout)
        event('contract-complete', seconds=result['contractSeconds'])
        time.sleep(phase_seconds)
        stop_loads()
        receipt = cluster.sql(database, 'select current,min_version,compat_floor from notes.tesl_schema_state')
        if receipt != '2|2|2':
            raise RuntimeError(f'wrong final admission: {receipt}')
        if int(cluster.sql(database, 'select count(*) from notes.notes where _tesl_v<>2')):
            raise RuntimeError('Contract retained an old generation')
        if int(cluster.sql(database, 'select count(*) from notes.notes')) != rows:
            raise RuntimeError('rollout lost rows')
        expected = {'r000000000000': 'repaired'}
        for load in result['loads']:
            if not load['label'].startswith('control-'):
                expected.update(load['finalAcknowledgedValues'])
        expected_json = json.dumps(expected, sort_keys=True).replace("'", "''")
        invalid = cluster.sql(database, f"""with expected as (select '{expected_json}'::jsonb as doc)
select count(*) from notes.notes n cross join expected e
where n.owner is distinct from 'original-owner'
 or n.memo is distinct from 'retained-memo' or n.title is distinct from n.id
 or coalesce((to_jsonb(n)->'metadata__v2')->>'message',(to_jsonb(n)->'metadata')->>'message')
    is distinct from coalesce(e.doc->>n.id,n.id)
 or case when e.doc ? n.id then
      coalesce((to_jsonb(n)->'metadata__v2')->>'detail',(to_jsonb(n)->'metadata')->>'detail','')
        not in ('migrated-v2','writer-v2')
    else coalesce((to_jsonb(n)->'metadata__v2')->>'detail',(to_jsonb(n)->'metadata')->>'detail')
      is distinct from 'migrated-v2' end""", timeout=180)
        if int(invalid):
            raise RuntimeError('Contract changed retained fields or lost converted/acknowledged values')
        result['allRowValuesVerified'] = True
        if cluster.sql(database, "select indisvalid from pg_index where indexrelid='lookup.active_lookup'::regclass") != 't':
            raise RuntimeError('concurrent managed index did not become valid')
        cluster.stop(worker)
        worker, _ = cluster.start(programs['v2'], database, True, batch)
        cluster.stop(new)
        new, new_port = cluster.start(programs['v2'], database)
        validate_row(http_request(new_port, 'GET', f'/row/{reject_key}')[0], reject_key, 2, 'repaired')
        event('post-contract-worker-and-request-restart-verified')
        for process in (worker, new, index_worker):
            cluster.stop(process)
        result['locks'] = observer.stop()
        observer = None
        result['summaries'] = {name: phase_summary([load]) for load in result['loads'] for name in [load['label']]}
        largest = max(args.clients)
        result['observedBudgets'] = {}
        for version in (1, 2):
            control = result['summaries'][f'control-v{version}-c{largest}']
            candidate = result['summaries'][f'overlap-v{version}']
            result['observedBudgets'][f'v{version}'] = {
                'read': compare_budget(control.get('read', summarize([])), candidate.get('read', summarize([])), .01),
                'write': compare_budget(control.get(args.transaction, summarize([])), candidate.get(args.transaction, summarize([])), .05)}
        result['phaseSummaries'] = {name: phase_summary(result['loads'], name)
                                    for name in sorted({o['phase'] for load in result['loads'] for o in load['observations']})}
        result['correctnessPassed'] = True
        result['status'] = 'correctness-passed'
        return result
    except (ObservationBudgetExceeded, ResourceLimitExceeded) as error:
        result['error'] = str(error)
        result['status'] = 'observation-budget-exhausted' if isinstance(error, ObservationBudgetExceeded) else 'resource-refused'
        return result
    except BaseException as error:
        result['error'] = str(error)
        result['status'] = 'failed'
        if isinstance(error, KeyboardInterrupt):
            cluster.stop_all()
        raise
    finally:
        for load in active:
            load.stop_event.set()
        while active:
            result['loads'].append(active.pop().stop())
        result['steadyBackfill'] = backfill_rate(result['progress'])
        if any(load.get('failures') for load in result['loads']):
            result['status'] = 'failed'
            result['error'] = 'request correctness failures observed'
        if observer:
            result['locks'] = observer.stop()
        if blocker:
            blocker.execute('rollback')
            blocker.close()
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        # Only private databases created by this case are removed.
        cluster.stop_all()
        for name in [database, *controls]:
            cluster.sql('postgres', f'drop database if exists {name}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--compiler', type=Path)
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--correctness-smoke', action='store_true')
    parser.add_argument('--retain-postgres-data', action='store_true', help='retain stopped private cluster for debugging')
    parser.add_argument('--rows', type=int, nargs='+', default=[1000, 10000, 100000, 1000000, 10000000, 100000000])
    parser.add_argument('--clients', type=int, nargs='+', default=[1, 4, 8, 16])
    parser.add_argument('--seconds', type=float, default=5)
    parser.add_argument('--batch', type=int, default=2000)
    parser.add_argument('--max-rollout-seconds', type=int, default=600)
    parser.add_argument('--lock-sample-seconds', type=float, default=.002)
    parser.add_argument('--transaction', choices=['write', 'mixed', 'ten'], default='write')
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    if min(args.rows) < 1000 or min(args.clients) < 1 or max(args.clients) >= 100 or args.seconds <= 0 or not 1 <= args.batch <= 10000:
        parser.error('rows>=1000; clients1–99; seconds>0; batch1–10000 required')
    args.artifacts = args.artifacts.resolve()
    args.output = args.output.resolve()
    args.source_root = args.source_root.resolve()
    compiler = args.compiler or args.source_root / 'compiler/_build/default/bin/main.exe'
    if not (args.artifacts / 'build.json').exists():
        build_artifacts(args.source_root, compiler, args.artifacts)
    manifest = json.loads((args.artifacts / 'build.json').read_text())
    for program in manifest['programs'].values():
        if digest(Path(program['binary'])) != program['sha256']:
            raise RuntimeError('built benchmark executable changed')
    if args.build_only:
        return
    args.output.mkdir(parents=True, exist_ok=False)
    if args.correctness_smoke:
        args.rows, args.clients, args.seconds = [1000], [2], min(args.seconds, 1)
    evidence = {'mode': 'correctness-smoke' if args.correctness_smoke else 'performance-observation',
                'status': 'incomplete', 'cases': [], 'compilerSha256': manifest['compilerSha256'],
                'programs': manifest['programs'], 'host': dict(zip(('system', 'node', 'release', 'version', 'machine'), os.uname())),
                'referenceCoverage': {'postgres16': False, 'pinnedHardware': False, 'replica': False,
                                      'poolers': False, 'oneMsNetwork': False, 'tenTables': False,
                                      'coldOperatingSystemCache': False, 'completeFailpointSweep': False},
                'releaseAcceptance': 'incomplete',
                'comparison': 'same generated plain V1/V2 HTTP controls versus active migration workload; not isolated admission-only overhead',
                'originalBudgets': {'readP99AdditionalRatio': .01, 'writeP99AdditionalRatio': .05}}
    cluster = None
    try:
        cluster = Cluster(args.output, retain_data=args.retain_postgres_data)
        evidence['postgres'] = command(['pg_ctl', '--version']).stdout.strip()
        measured_bytes = 256
        for rows in args.rows:
            estimate = resource_estimate(rows, measured_bytes, shutil.disk_usage(args.output).free)
            if not estimate['allowed']:
                evidence['cases'].append({'rows': rows, 'status': 'resource-refused', 'estimate': estimate})
                continue
            try:
                result = run_case(args, manifest, cluster, rows, args.output / str(rows))
                measured_bytes = max(measured_bytes, result['resources'].get('bytesPerRow', measured_bytes))
                evidence['cases'].append({k: v for k, v in result.items() if k not in ('loads', 'locks')})
            except Exception as error:
                evidence['cases'].append({'rows': rows, 'status': 'failed', 'error': str(error)})
                # Preserve failure evidence, then attempt the remaining feasible sizes.
            (args.output / 'result.json').write_text(json.dumps(evidence, indent=2) + '\n')
        evidence['status'] = 'correctness-passed' if all(c['status'] == 'correctness-passed' for c in evidence['cases']) else 'incomplete-or-failed'
        if args.correctness_smoke and evidence['status'] != 'correctness-passed':
            raise RuntimeError('rolling workload correctness smoke failed')
    finally:
        if cluster:
            cluster.close()
        (args.output / 'result.json').write_text(json.dumps(evidence, indent=2) + '\n')


if __name__ == '__main__':
    main()

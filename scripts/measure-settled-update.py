#!/usr/bin/env python3
"""Measure real HTTP bulk updates after the ordinary V2 Retype/Contract fixture.

Prepare sources with example/db-three-upgrades/run.py --build-only, then pass
its v2/source directory. Use identical sources and alternating baseline/candidate
--repo-root values. Owns a private PostgreSQL cluster with pg_stat_statements.
No performance threshold, latency acceptance substitute, or test-result cache.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import socket
import statistics
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise RuntimeError(f'fixture boundary changed: {old}')
    return source.replace(old, new, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo-root', type=Path, default=ROOT)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--rows', type=int, nargs='+', default=[1, 100, 1000])
    parser.add_argument('--samples', type=int, default=8)
    parser.add_argument('--warmup', type=int, default=2)
    args = parser.parse_args()
    if args.samples < 1 or args.warmup < 1 or any(n < 1 or n > 10000 for n in args.rows):
        parser.error('positive samples/warmup and row counts from 1 to 10000 required')
    repo, original, output = args.repo_root.resolve(), args.source.resolve(), args.output.resolve()
    if original == output or original in output.parents or output in original.parents:
        parser.error('output and source must be separate trees')
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    helpers = runpy.run_path(str(ROOT / 'example/db-three-upgrades/run.py'))
    command, eventually = helpers['command'], helpers['eventually']
    # Inherited libpq service/host-address settings must never redirect fixture
    # commands to another database. Both builds use the normal RMW batch size.
    env = {key: value for key, value in os.environ.items() if not key.startswith('PG')}
    env.update(TESL_REPO_ROOT=str(repo), GOWORK='off', TESL_RMW_BATCH='2000')
    compiler = repo / 'compiler/_build/default/bin/main.exe'
    evidence = {'status': 'incomplete', 'repoRoot': str(repo), 'source': str(original),
                'samples': args.samples, 'warmup': args.warmup, 'rmwBatch': 2000, 'cases': []}
    processes = []
    data, sockets = output / 'postgres-data', output / 'socket'
    sockets.mkdir(mode=0o700)
    # PostgreSQL Unix socket paths are bounded independently of artifact paths.
    if len(str(sockets / '.s.PGSQL.5432').encode()) > 107:
        parser.error('use a shorter output path for PostgreSQL sockets')
    pg = dict(env, PGHOST=str(sockets), PGPORT='5432', PGUSER='demo_installer', PGDATABASE='postgres')
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]

    def sql(statement, database='bulkbench'):
        return command(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-Atc', statement], env=dict(pg, PGDATABASE=database))

    def appenv(role):
        return dict(env, DEMO_HOST=str(sockets), DEMO_PORT='5432', DEMO_DB='bulkbench', DEMO_OWNER='demo_owner',
                    DEMO_WORKER='demo_worker', DEMO_REQUEST='demo_request', DEMO_USER=role, DEMO_HTTP_PORT=str(port),
                    DEMO_DDL=f'host={sockets} dbname=bulkbench user={role}')

    def request(method, path):
        with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}' + path, method=method), timeout=120) as response:
            return json.load(response)

    try:
        source = output / 'source'
        shutil.copytree(original, source)
        evidence['sourceHashes'] = {str(file.relative_to(source)): hashlib.sha256(file.read_bytes()).hexdigest()
                                    for file in sorted(source.rglob('*')) if file.is_file()}
        app = (source / 'app.tesl').read_text()
        app = replace_once(app, 'api NotesApi {', 'api NotesApi {\nput "/bulk-edit" -> String\nput "/bulk-repair" -> String')
        app = replace_once(app, 'server NotesServer for NotesApi {', '''handler put bulkEdit() -> String requires [dbWrite Note] =
  update note in Note
    where note.id != ""
    set note.metadata = makeMetadata "bulk-edited"
  "bulk-edited"
handler put bulkRepair() -> String requires [dbWrite Note] =
  update note in Note
    where note.id != ""
    set note.metadata = makeMetadata "bulk-repaired"
  "bulk-repaired"
server NotesServer for NotesApi { bulkEdit, bulkRepair,''')
        (source / 'app.tesl').write_text(app)
        evidence['appSha256'] = hashlib.sha256(app.encode()).hexdigest()
        evidence['compilerSha256'] = hashlib.sha256(compiler.read_bytes()).hexdigest()
        for file in sorted(source.rglob('*.tesl')):
            context = json.loads(command([compiler, 'agent-context', file], env=env, timeout=300))
            if not context['ok']:
                raise RuntimeError(json.dumps(context))
        command([compiler, '--backend', 'go', source / 'app.tesl', '--out', output / 'go'], env=env, timeout=300)
        history = json.loads((output / 'go/migration-source-history.json').read_text())
        if len(history['databases']) != 1 or history['databases'][0]['currentVersion'] != 2:
            raise RuntimeError('benchmark requires the ordinary V2 fixture')
        command(['go', 'build', '-o', output / 'app', './cmd/app'], cwd=output / 'go', env=env, timeout=300)
        evidence['binarySha256'] = hashlib.sha256((output / 'app').read_bytes()).hexdigest()
        evidence['tools'] = {name: command(cmd).strip() for name, cmd in
                             [('go', ['go', 'version']), ('postgres', ['pg_ctl', '--version'])]}
        command(['initdb', '-D', data, '-U', 'demo_installer', '--auth=trust', '--no-locale', '--encoding=UTF8'], env=env)
        command(['pg_ctl', '-D', data, '-l', output / 'postgres.log', '-o',
                 f"-k {sockets} -h '' -p 5432 -c shared_preload_libraries=pg_stat_statements", '-w', 'start'], env=env)
        sql('create role demo_owner nologin; create role demo_worker login; create role demo_request login', 'postgres')
        sql('create database bulkbench', 'postgres')
        sql('grant create on database bulkbench to demo_owner', 'postgres')
        sql('grant create on schema public to demo_owner; create extension pg_stat_statements')
        command([output / 'app', '--schema', 'install', '--worker', 'demo_worker', '--request', 'demo_request', '--json'], env=appenv('demo_installer'))
        for role, options in [('demo_worker', ['--schema', 'worker', '--json']), ('demo_request', [])]:
            log = (output / f'{role}.log').open('w')
            proc = subprocess.Popen([str(output / 'app'), *options], env=appenv(role), stdout=log, stderr=log)
            processes.append((proc, log))

            def ready():
                if proc.poll() is not None:
                    raise RuntimeError(f'{role} exited; see {log.name}')
                return 'schema-worker-ready' in Path(log.name).read_text() if options else request('GET', '/health') == 'ready'

            eventually(ready)
        command([output / 'app', '--schema', 'contract', 'V2', '--json'], env=appenv('demo_worker'))
        if sql('select current||\',\'||min_version||\',\'||compat_floor from notes.tesl_schema_state').strip() != '2,2,2':
            raise RuntimeError('fixture did not reach settled V2')
        for count in args.rows:
            # Fixture loading is outside timing. Every value is checked again
            # through the real typed HTTP read after every measured operation.
            sql("truncate notes.notes; insert into notes.notes(id,metadata__v2,owner,memo,title,_tesl_v) "
                "select 'r'||i,jsonb_build_object('message','kept','detail','writer-v2'),"
                "'original-owner','retained-memo','kept',2 from generate_series(1," + str(count) + ') i')
            case = {'rows': count, 'observations': []}
            evidence['cases'].append(case)
            for index in range(args.warmup + args.samples):
                operation, expected = ('bulk-edit', 'bulk-edited') if index % 2 == 0 else ('bulk-repair', 'bulk-repaired')
                sql('select pg_stat_statements_reset()')
                started = time.perf_counter_ns()
                if request('PUT', '/' + operation) != expected:
                    raise RuntimeError('wrong update acknowledgement')
                write_ns = time.perf_counter_ns() - started
                queries = json.loads(sql("select coalesce(json_agg(t),'[]') from (select query,calls,total_exec_time "
                                         "from pg_stat_statements where userid=(select oid from pg_roles where rolname='demo_request') "
                                         "order by calls desc,query) t"))
                started = time.perf_counter_ns()
                actual = request('GET', '/notes')
                read_ns = time.perf_counter_ns() - started
                if len(actual) != count or {row['id'] for row in actual} != {f'r{i}' for i in range(1, count + 1)}:
                    raise RuntimeError('row identity/count changed')
                if not all(row['metadata'] == {'message': expected, 'detail': 'writer-v2'} and
                           row['owner'] == 'original-owner' and row['memo'] == 'retained-memo' and row['title'] == 'kept' for row in actual):
                    raise RuntimeError('stored values or untouched fields changed')
                observation = {'index': index, 'warmup': index < args.warmup, 'write_ns': write_ns,
                               'read_ns': read_ns, 'correct': True, 'queries': queries}
                case['observations'].append(observation)
                (output / 'result.json').write_text(json.dumps(evidence, indent=2) + '\n')
            measured = [item for item in case['observations'] if not item['warmup']]
            case['write_median_ns'] = statistics.median(item['write_ns'] for item in measured)
            case['read_median_ns'] = statistics.median(item['read_ns'] for item in measured)
            print(json.dumps({'rows': count, 'write_median_ms': case['write_median_ns'] / 1e6,
                              'read_median_ms': case['read_median_ns'] / 1e6,
                              'request_role_query_calls': [sum(q['calls'] for q in item['queries']) for item in measured]}), flush=True)
        evidence['status'] = 'correctness-passed'
    except BaseException as error:
        evidence['status'], evidence['error'] = 'failed', str(error)
        raise
    finally:
        for proc, log in reversed(processes):
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            log.close()
        subprocess.run(['pg_ctl', '-D', str(data), '-m', 'immediate', '-w', 'stop'], capture_output=True)
        (output / 'result.json').write_text(json.dumps(evidence, indent=2) + '\n')


if __name__ == '__main__':
    main()

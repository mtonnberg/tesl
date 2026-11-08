#!/usr/bin/env python3
"""Measure compiled nullable PostgreSQL predicates through ordinary HTTP.

Run this script with alternating baseline/candidate --repo-root values and the
same --fixture. It never builds either compiler. Each invocation owns a private
cluster, builds an ordinary release application, and installs the SAME existing
owner B-tree outside timing. Legacy compiler index creation is not being tested.

Synthetic unauthenticated workload: path captures select fixed server-generated
nullable operands, not uploaded lists. Timings include HTTP response transfer;
JSON parsing, full-value validation, seeding, VACUUM and EXPLAIN are outside them.
Default auto mode uses PostgreSQL's actual default, without SET or role override.
Optional force_generic_plan is a separately labelled control. No timing gate or
production p99 claim. Uses psql, not a Python PostgreSQL driver.
"""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import socket
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SPECIAL = "owner'雪;--"
OPERANDS = {
    'eq': {'hit': 'owner-7', 'null': None, 'miss': 'absent-owner', 'special': SPECIAL},
    'in': {'hit': ['owner-7', 'owner-19'], 'mixed': [None, 'owner-7', 'owner-19'],
           'null': [None], 'empty': [], 'miss': ['absent-owner'],
           'duplicates': ['owner-7', None, 'owner-7', None],
           'special': [SPECIAL, 'absent-owner']},
}
INDEX_SQL = 'create index items_owner_bench_idx on nullable_bench.items using btree (owner)'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def literal(value):
    return 'NULL' if value is None else "'" + value.replace("'", "''") + "'"


def operand_sql(operation, value):
    if operation == 'eq':
        return literal(value) + '::text'
    return 'ARRAY[' + ','.join(literal(item) for item in value) + ']::text[]'


def expected_results(count):
    """Independent Python value oracle; no database query supplies expectations."""
    selected = {(op, name): [] for op, cases in OPERANDS.items() for name in cases}
    wanted = {(op, name): set(value if op == 'in' else [value])
              for op, cases in OPERANDS.items() for name, value in cases.items()}
    for index in range(count):
        bucket = index % 10000
        owner = None if bucket == 0 else SPECIAL if bucket == 23 else f'owner-{bucket}'
        if owner not in {None, 'owner-7', 'owner-19', SPECIAL}:
            continue
        encoded_owner = {'tag': 'Nothing'} if owner is None else {'tag': 'Something', 'fields': {'value': owner}}
        row = {'id': index, 'owner': encoded_owner, 'score': 9223372036854775808 + index,
               'label': f'row-{index}', 'payload': 'kept-' + 'x' * 64, 'active': index % 2 == 0}
        for key, members in wanted.items():
            if owner in members:
                selected[key].append(row)
    return {f'/{op}/{shape}/{name}': len(rows) if shape == 'count' else rows
            for (op, name), rows in selected.items() for shape in ['count', 'rows']}


def emitted_statements(directory):
    """Extract exact compiler-emitted PgSql literals, never hand-rewrite a plan."""
    found = {}
    for file in sorted(directory.rglob('module.go')):
        for quoted in re.findall(r'teslrt\.PgSql\(("(?:[^"\\]|\\.)*")', file.read_text()):
            sql = json.loads(quoted)
            if ' from "nullable_bench"."items"' not in sql:
                continue
            operation = 'in' if 'array_position(' in sql.lower() or 'any(' in sql.lower() or 'any (' in sql.lower() else 'eq'
            shape = 'count' if sql.startswith('select count(*)') else 'rows'
            key = operation + '/' + shape
            if key in found and found[key] != sql:
                raise RuntimeError(f'multiple different emitted statements for {key}')
            if set(re.findall(r'\$\d+', sql)) != {'$1'}:
                raise RuntimeError(f'fixture must bind exactly one operand: {sql}')
            found[key] = sql
    if set(found) != {'eq/count', 'eq/rows', 'in/count', 'in/rows'}:
        raise RuntimeError(f'expected four compiled query shapes, found {found}')
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo-root', type=Path, default=ROOT)
    parser.add_argument('--fixture', type=Path, default=ROOT / 'bench/NullablePostgres.tesl')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--rows', type=int, nargs='+', default=[100000, 1000000])
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--warmup', type=int, default=8)
    parser.add_argument('--plan-modes', nargs='+', choices=['auto', 'force_generic_plan'], default=['auto'])
    args = parser.parse_args()
    if args.samples < 1 or args.warmup < 1 or any(n < 100 or n > 10000000 for n in args.rows):
        parser.error('positive samples/warmup and 100..10000000 rows required')
    if len(set(args.rows)) != len(args.rows) or len(set(args.plan_modes)) != len(args.plan_modes):
        parser.error('row counts and plan modes must not repeat')
    repo, output = args.repo_root.resolve(), args.output.resolve()
    compiler = repo / 'compiler/_build/default/bin/main.exe'
    if not compiler.is_file():
        parser.error(f'build the selected compiler separately first: {compiler}')
    # No inherited libpq service, hostaddr, options, or application settings can
    # redirect commands or silently change auto-mode query planning.
    env = {k: v for k, v in os.environ.items() if not k.startswith(('PG', 'BENCH_', 'TESL_'))}
    env.update(TESL_REPO_ROOT=str(repo), GOWORK='off')
    output.mkdir(parents=True, mode=0o700, exist_ok=False)
    data, sockets = output / 'postgres-data', output / 'socket'
    sockets.mkdir(mode=0o700)
    if len(str(sockets / '.s.PGSQL.5432').encode()) > 107:
        parser.error('use a shorter output path for PostgreSQL sockets')
    pg = dict(env, PGHOST=str(sockets), PGPORT='5432', PGUSER='bench_admin', PGDATABASE='nullablebench')
    evidence = {'version': 1, 'status': 'incomplete', 'repoRoot': str(repo),
                'scope': 'synthetic unauthenticated compiled HTTP; server-generated operands; existing owner index',
                'rows': args.rows, 'samples': args.samples, 'warmup': args.warmup,
                'planModes': args.plan_modes, 'operands': OPERANDS, 'indexSQL': INDEX_SQL,
                'poolSize': 1, 'cases': [], 'plans': [], 'errors': []}
    process = connection = log = None
    pg_started = False

    def persist():
        (output / 'result.json').write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + '\n')

    def command(arguments, *, cwd=None, environment=None, stdin=None, timeout=300):
        result = subprocess.run(list(map(str, arguments)), cwd=cwd, env=environment or env,
                                input=stdin, text=True, capture_output=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(f'{arguments}: exit {result.returncode}\n{result.stdout}\n{result.stderr}')
        return result.stdout

    def sql(statement, *, database='nullablebench', role='bench_admin'):
        return command(['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
                       environment=dict(pg, PGDATABASE=database, PGUSER=role), stdin=statement + '\n')

    def request(path):
        started = time.perf_counter_ns()
        connection.request('GET', path)
        response = connection.getresponse()
        raw = response.read()
        elapsed = time.perf_counter_ns() - started
        if response.status != 200:
            raise RuntimeError(f'{path}: HTTP {response.status}: {raw!r}')
        return json.loads(raw), elapsed, len(raw)

    def stop_app():
        nonlocal process, connection, log
        if connection is not None:
            connection.close()
            connection = None
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            process = None
        if log is not None:
            log.close()
            log = None

    def start_app(mode):
        nonlocal process, connection, log
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        log = (output / f'server-{mode}.log').open('w')
        app_env = dict(env, BENCH_HOST=str(sockets), BENCH_PG_PORT='5432',
                       BENCH_DATABASE='nullablebench', BENCH_USER='bench_request', BENCH_PASSWORD='',
                       BENCH_HTTP_PORT=str(port))
        process = subprocess.Popen([str(output / 'app')], env=app_env, stdout=log, stderr=log)
        deadline = time.monotonic() + 30
        while True:
            if process.poll() is not None:
                raise RuntimeError(f'application exited; see {log.name}')
            try:
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=120)
                if request('/health')[0] == 'ready':
                    return
            except OSError:
                connection.close()
            if time.monotonic() >= deadline:
                raise RuntimeError('application readiness timed out')
            time.sleep(.05)

    def explain(mode, count, statements):
        # Same role, settings, statement text, and operand values as HTTP. These
        # are separate diagnostic sessions, not the application's prepared cache.
        # Warm PREPARE with the same scenario sequence; retain PostgreSQL's own
        # generic/custom counters rather than labelling every auto plan custom.
        for key, statement in statements.items():
            operation, shape = key.split('/')
            cases = OPERANDS[operation]
            parameter_type = 'text' if operation == 'eq' else 'text[]'
            lines = [f'prepare measured({parameter_type}) as {statement};', '\\o /dev/null']
            for _ in range(max(6, args.warmup)):
                for value in cases.values():
                    lines.append(f'execute measured({operand_sql(operation, value)});')
            lines.append('\\o')
            for name, value in cases.items():
                lines.extend([f'\\echo PLAN:{name}',
                              'explain (analyze, buffers, format json) execute measured('
                              + operand_sql(operation, value) + ');'])
            lines.extend(['\\echo COUNTERS',
                          "select row_to_json(p) from (select generic_plans,custom_plans from pg_prepared_statements where name='measured') p;"])
            raw = sql('\n'.join(lines), role='bench_request')
            file = output / f'plans-{mode}-{count}-{operation}-{shape}.txt'
            file.write_text(raw)
            before_counters, counters = raw.split('COUNTERS\n', 1)
            plans = {}
            for chunk in before_counters.split('PLAN:')[1:]:
                name, plan = chunk.split('\n', 1)
                plans[name] = json.loads(plan)
            if set(plans) != set(cases):
                raise RuntimeError('incomplete EXPLAIN evidence')
            evidence['plans'].append({'mode': mode, 'rows': count, 'shape': key,
                                      'sql': statement, 'plans': plans,
                                      'preparedCounters': json.loads(counters), 'rawFile': file.name})

    try:
        source = output / 'NullablePostgres.tesl'
        source.write_bytes(args.fixture.read_bytes())
        evidence.update(sourceSha256=digest(source), compilerSha256=digest(compiler),
                        runnerSha256=digest(Path(__file__)))
        checked = json.loads(command([compiler, 'agent-context', source]))
        evidence['agentContext'] = checked
        if not checked['ok']:
            raise RuntimeError('fixture failed agent-context')
        command([compiler, '--backend', 'go', source, '--out', output / 'go'])
        statements = emitted_statements(output / 'go')
        evidence['sqlStatements'] = statements
        evidence['generatedSourceHashes'] = {str(f.relative_to(output / 'go')): digest(f)
                                             for f in sorted((output / 'go').rglob('*.go'))}
        command(['go', 'build', '-trimpath', '-o', output / 'app', './cmd/app'], cwd=output / 'go')
        evidence['binarySha256'] = digest(output / 'app')
        evidence['tools'] = {name: command(cmd).strip() for name, cmd in
                             [('go', ['go', 'version']), ('postgres', ['pg_ctl', '--version']),
                              ('python', ['python3', '--version'])]}
        command(['initdb', '-D', data, '-U', 'bench_admin', '--auth=trust', '--no-locale', '--encoding=UTF8'])
        command(['pg_ctl', '-D', data, '-l', output / 'postgres.log', '-o',
                 f"-k {sockets} -h '' -p 5432", '-w', 'start'])
        pg_started = True
        sql('create role bench_request login;', database='postgres')
        sql('create database nullablebench owner bench_request;', database='postgres')
        for mode in args.plan_modes:
            if mode == 'auto':
                sql('alter role bench_request in database nullablebench reset plan_cache_mode;')
            else:
                sql('alter role bench_request in database nullablebench set plan_cache_mode=force_generic_plan;')
            setting = json.loads(sql("select row_to_json(p) from (select setting,source from pg_settings where name='plan_cache_mode') p;",
                                     role='bench_request'))
            if setting['setting'] != mode or mode == 'auto' and setting['source'] != 'default':
                raise RuntimeError(f'wrong effective plan mode: {setting}')
            start_app(mode)
            if not evidence.get('indexCatalog'):
                sql(INDEX_SQL + ';')
                evidence['indexCatalog'] = json.loads(sql("select row_to_json(p) from (select indexdef from pg_indexes where schemaname='nullable_bench' and indexname='items_owner_bench_idx') p;"))
            for count in args.rows:
                sql('truncate nullable_bench.items; insert into nullable_bench.items(id,owner,score,label,payload,active) '
                    f"select i,case when i%10000=0 then null when i%10000=23 then {literal(SPECIAL)} else 'owner-'||(i%10000)::text end,"
                    f"9223372036854775808::numeric+i,'row-'||i::text,'kept-'||repeat('x',64),i%2=0 from generate_series(0,{count - 1}) i;")
                sql('vacuum (analyze) nullable_bench.items;')
                expected = expected_results(count)
                # Independent storage summary detects missing/extra seeded rows.
                summary = json.loads(sql('select row_to_json(p) from (select count(*) as count,min(id) as minimum,max(id) as maximum,sum(id) as total from nullable_bench.items) p;'))
                if summary != {'count': count, 'minimum': 0, 'maximum': count - 1, 'total': count * (count - 1) // 2}:
                    raise RuntimeError(f'seed summary differs: {summary}')
                case = {'mode': mode, 'planSetting': setting, 'rows': count, 'seedSummary': summary,
                        'expectedCounts': {path: value if '/count/' in path else len(value) for path, value in expected.items()},
                        'observations': []}
                evidence['cases'].append(case)
                persist()
                for iteration in range(args.warmup + args.samples):
                    for path, want in expected.items():
                        actual, elapsed, size = request(path)
                        observation = {'iteration': iteration, 'path': path, 'ns': elapsed,
                                       'responseBytes': size, 'warmup': iteration < args.warmup, 'correct': actual == want}
                        case['observations'].append(observation)
                        if actual != want:
                            (output / 'incorrect-response.json').write_text(json.dumps({'path': path, 'expected': want, 'actual': actual}, indent=2))
                            raise RuntimeError(f'{path}: wrong count, IDs, order, NULLs or full row values')
                    persist()
                case['median_ms'] = {path: statistics.median(item['ns'] for item in case['observations']
                                                            if item['path'] == path and not item['warmup']) / 1e6
                                     for path in expected}
                explain(mode, count, statements)
                persist()
                print(json.dumps({'rows': count, 'mode': mode, 'median_ms': case['median_ms']}), flush=True)
            stop_app()
        if digest(compiler) != evidence['compilerSha256'] or digest(output / 'app') != evidence['binarySha256']:
            raise RuntimeError('compiler or application binary changed during measurement')
        evidence['status'] = 'correctness-passed'
    except BaseException as error:
        evidence['status'] = 'failed'
        evidence['errors'].append(str(error))
        raise
    finally:
        stop_app()
        if pg_started:
            stopped = subprocess.run(['pg_ctl', '-D', str(data), '-m', 'immediate', '-w', 'stop'],
                                     env=env, capture_output=True, text=True, timeout=30)
            if stopped.returncode:
                evidence['status'] = 'failed'
                evidence['errors'].append('private PostgreSQL shutdown failed: ' + stopped.stderr)
        persist()


if __name__ == '__main__':
    main()

"""Helpers for the real old/new-process migration workload (standard library)."""
import concurrent.futures
from fractions import Fraction
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import re
import runpy
import shutil
import socket
import subprocess
import tempfile
import threading
import time


def command(arguments, *, env=None, cwd=None, timeout=180, check=True):
    result = subprocess.run(list(map(str, arguments)), env=env, cwd=cwd,
                            capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f'{arguments}: {result.returncode}\n{result.stdout}\n{result.stderr}')
    return result


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def quantile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def resource_estimate(rows, bytes_per_row, free_bytes, reserve_bytes=2 << 30):
    # Retained source, target materialization/MVCC, indexes, temporary index
    # work and WAL must coexist. This is a conservative fixture bound, not a
    # promise about an arbitrary application's row shape or checkpoint timing.
    estimated = math.ceil(rows * bytes_per_row * 8)
    return {'rows': rows, 'bytesPerRow': bytes_per_row, 'multiplier': 8,
            'estimatedPeakBytes': estimated, 'freeBytes': free_bytes,
            'reservedBytes': reserve_bytes, 'allowed': estimated + reserve_bytes < free_bytes}


def summarize(observations):
    successful = [item['elapsedNs'] for item in observations if item['ok']]
    return {'samples': len(observations), 'errors': sum(not item['ok'] for item in observations),
            **({f'p{int(q * 100)}Ns': quantile(successful, q) for q in (.5, .95, .99)}
               if successful else {'p50Ns': None, 'p95Ns': None, 'p99Ns': None})}


def compare_budget(control, candidate, budget):
    if (control['errors'] or candidate['errors'] or control['p99Ns'] is None
            or candidate['p99Ns'] is None or min(control['samples'], candidate['samples']) < 1000):
        return {'budgetRatio': budget, 'observedPassed': False, 'verdict': 'insufficient-or-failed-evidence'}
    ratio = candidate['p99Ns'] / control['p99Ns'] - 1
    # Exact integer-nanosecond acceptance; retain the ratio only for reporting.
    limit = Fraction(str(budget))
    passed = candidate['p99Ns'] * limit.denominator <= control['p99Ns'] * (limit.denominator + limit.numerator)
    return {'budgetRatio': budget, 'p99AdditionalRatio': ratio,
            'observedPassed': passed,
            'verdict': 'observed-pass' if passed else 'observed-fail'}


def app_source(base, *, plain=False, index=False):
    # Keep the same generated HTTP/codec/SQL implementation for the plain
    # control. Only its database migration configuration/schema ownership differ.
    prefix = base[:base.index('api NotesApi')]
    prefix = prefix.replace('import Tesl.App exposing [App]',
                            'import Tesl.App exposing [App]\nimport Tesl.Json exposing [stringCodec]')
    prefix = prefix.replace('namespace: "notes"', 'namespace: "lookup"' if index else 'namespace: "notes"')
    if plain:
        prefix = prefix.replace('import Schema.Notes.VCurrent exposing', 'import Model exposing')
        prefix = prefix.replace('schema: Schema.Notes.VCurrent\nmigrations: Schema.Notes.Migrate\n',
                                'schema: "notes"\nentities: [Note]\n')
        prefix = prefix.replace('  namespace: "notes"\n', '')
        start = prefix.index('  migrations: MigrationConfig {')
        end = prefix.index('\n  }', start) + len('\n  }')
        prefix = prefix[:start] + prefix[end:]
    if index:
        prefix = prefix.replace('Schema.Notes', 'Schema.Lookup')
    update = 'update note in Note\n      where note.id == id\n      set note.metadata = makeMetadata value'
    reads = 'select note from Note where note.id == id'
    ten = '\n'.join('    let _ = ' + (reads if i % 2 == 0 else update) for i in range(10))
    return prefix + '''
capturer benchmarkId: id: String using stringCodec
capturer benchmarkValue: value: String using stringCodec
api PerfApi {
 get "/health" -> String
 get "/row/:id" capture id: String via benchmarkId -> List Note
 put "/row/:id/:value" capture id: String via benchmarkId capture value: String via benchmarkValue -> String
 post "/mixed/:id/:value" capture id: String via benchmarkId capture value: String via benchmarkValue -> String
 post "/ten/:id/:value" capture id: String via benchmarkId capture value: String via benchmarkValue -> String
}
handler get health() -> String = "ready"
handler get readRow(id: String) -> List Note requires [dbRead Note] =
  ''' + reads + '''
handler put writeRow(id: String, value: String) -> String requires [dbWrite Note] =
  let _ = ''' + update + '''
  value
handler post mixedRow(id: String, value: String) -> String requires [dbRead Note, dbWrite Note] =
  transaction {
    let _ = ''' + reads + '''
    let _ = ''' + update + '''
    value
  }
handler post tenStatements(id: String, value: String) -> String requires [dbRead Note, dbWrite Note] =
  transaction {
''' + ten + '''
    value
  }
server PerfServer for PerfApi { health, readRow, writeRow, mixedRow, tenStatements, listenAddress Loopback }
main() -> App requires [dbRead Note, dbWrite Note, envRead] =
  App { database: Main, api: PerfServer, port: envInt "DEMO_HTTP_PORT" 8080 }
'''


def build_artifacts(root, compiler, destination):
    destination.mkdir(parents=True, exist_ok=False)
    common = runpy.run_path(str(root / 'example/db-three-upgrades/run.py'))
    example = root / 'example/db-three-upgrades'
    env = dict(os.environ, TESL_REPO_ROOT=str(root), GOWORK='off')
    base_app = (example / 'app.tesl').read_text()
    manifest = {'compilerSha256': digest(compiler), 'sourceRoot': str(root), 'programs': {}}

    def compile_program(source, name):
        entry = source / 'app.tesl'
        result = json.loads(command([compiler, 'agent-context', entry], env=env).stdout)
        if not result['ok']:
            raise RuntimeError(json.dumps(result))
        generated = destination / name / 'go'
        command([compiler, '--backend', 'go', entry, '--out', generated], env=env)
        binary = destination / name / 'app'
        command(['go', 'build', '-trimpath', '-o', binary, './cmd/app'], env=env, cwd=generated)
        source_hashes = {str(p.relative_to(source)): digest(p) for p in sorted(source.rglob('*')) if p.is_file()}
        manifest['programs'][name] = {'binary': str(binary), 'sha256': digest(binary), 'sourceSha256': source_hashes}
        print('Built', name, flush=True)

    source = destination / 'row-source'
    (source / 'schema/notes').mkdir(parents=True)
    shutil.copy2(example / 'tesl.toml', source / 'tesl.toml')
    (source / 'app.tesl').write_text(app_source(base_app))
    current = source / 'schema/notes/v-current.tesl'
    for version in (1, 2):
        if version == 1:
            shutil.copy2(example / 'schema/notes/v-current.tesl', current)
        else:
            common['apply_preview'](compiler, source / 'app.tesl', env, 'generate', '--new-revision')
            shutil.copy2(example / 'versions/v2.tesl', current)
            edge = source / 'migrations/notes/v2.tesl'
            header = edge.read_text().split('module ', 1)[0]
            edge.write_text(header + (example / 'transitions/v2.tesl').read_text())
            common['apply_preview'](compiler, source / 'app.tesl', env, 'generate')
            common['apply_preview'](compiler, source / 'app.tesl', env, 'contract', '--version', '2')
        compile_program(source, f'v{version}')
        plain = destination / f'plain{version}-source'
        plain.mkdir()
        shutil.copy2(source / 'tesl.toml', plain / 'tesl.toml')
        (plain / 'app.tesl').write_text(app_source(base_app, plain=True))
        model = current.read_text().replace('module Schema.Notes.VCurrent ', 'module Model ')
        model = re.sub(r'\s+@column\("[^"]+"\)', '', model)
        (plain / 'model.tesl').write_text(model)
        compile_program(plain, f'plain{version}')

    index_source = destination / 'index-source'
    (index_source / 'schema/lookup').mkdir(parents=True)
    shutil.copy2(source / 'tesl.toml', index_source / 'tesl.toml')
    (index_source / 'app.tesl').write_text(app_source(base_app, index=True))
    index_current = index_source / 'schema/lookup/v-current.tesl'
    index_schema = (example / 'schema/notes/v-current.tesl').read_text().replace('Schema.Notes', 'Schema.Lookup')
    # Bool has bounded PostgreSQL index keys. An unbounded String index can
    # reject a previously valid writer because PostgreSQL limits btree entries.
    index_schema = index_schema.replace('exposing [String]', 'exposing [String, Bool(..)]')
    index_schema = index_schema.replace('title: String }', 'title: String, active: Bool }')
    index_schema = index_schema.replace('title: text })', 'title: text, active: False })')
    for version in (1, 2):
        if version == 1:
            index_current.write_text(index_schema)
        else:
            common['apply_preview'](compiler, index_source / 'app.tesl', env, 'generate', '--new-revision')
            index_current.write_text(index_schema.replace('active: Bool }', 'active: Bool\n index [active] as "active_lookup"\n}'))
            common['apply_preview'](compiler, index_source / 'app.tesl', env, 'generate')
        compile_program(index_source, f'index{version}')
    (destination / 'build.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


class SQL:
    """One persistent psql connection, owned by a single observer thread."""
    def __init__(self, env, log):
        self.log = log.open('w')
        self.process = subprocess.Popen(['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
                                        env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.log, text=True, bufsize=1)

    def query(self, expression):
        self.process.stdin.write('select (' + expression + ')::text;\n')
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError('persistent SQL observer exited')
        return line.strip()

    def execute(self, statements):
        self.process.stdin.write(statements.rstrip(';') + ";\nselect 'tesl-benchmark-statement-complete';\n")
        self.process.stdin.flush()
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError('persistent SQL command exited')
            if line.strip() == 'tesl-benchmark-statement-complete':
                return

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        self.log.close()


class Cluster:
    def __init__(self, output, *, retain_data=False):
        self.output = output
        self.retain_data = retain_data
        self.closed = False
        self.data = output / 'postgres-data'
        self.socket = Path(tempfile.mkdtemp(prefix='tesl-rollout-', dir='/tmp'))
        self.processes = []
        self.env = dict(os.environ, PGHOST=str(self.socket), PGPORT='5432', PGUSER='bench_installer', PGDATABASE='postgres')
        try:
            command(['initdb', '-D', self.data, '-U', 'bench_installer', '--auth=trust', '--no-locale', '--encoding=UTF8'])
            command(['pg_ctl', '-D', self.data, '-l', output / 'postgres.log', '-o',
                     f"-k {self.socket} -h '' -c max_connections=120 -c track_functions=all -c log_lock_waits=on -c deadlock_timeout=1ms -c log_min_duration_statement=5 -c max_wal_size=512MB", '-w', 'start'])
            self.sql('postgres', 'create role demo_owner nologin; create role demo_worker login; create role demo_request login')
        except BaseException:
            self.close()
            raise

    def sql(self, database, query, role='bench_installer', timeout=180):
        return command(['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c', query],
                       env=dict(self.env, PGDATABASE=database, PGUSER=role), timeout=timeout).stdout.strip()

    def environment(self, database, role, port=0, batch=2000):
        return dict(os.environ, DEMO_HOST=str(self.socket), DEMO_PORT='5432', DEMO_DB=database,
                    DEMO_USER=role, DEMO_OWNER='demo_owner', DEMO_WORKER='demo_worker',
                    DEMO_REQUEST='demo_request', DEMO_HTTP_PORT=str(port),
                    DEMO_DDL=f'host={self.socket} dbname={database} user={role}',
                    TESL_BACKFILL_BATCH=str(batch), TESL_SCHEMA_POLL_S='1', TESL_LEASE_TTL_S='3')

    def schema(self, binary, database, role, *args, timeout=180, check=True):
        return command([binary, '--schema', *args, '--json'],
                       env=self.environment(database, role), timeout=timeout, check=check)

    def start(self, binary, database, worker=False, batch=2000, wait=True):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        path = self.output / f'{database}-{binary.parent.name}-{time.time_ns()}.log'
        log = path.open('w')
        process = subprocess.Popen([str(binary), *(['--schema', 'worker', '--json'] if worker else [])],
                                   env=self.environment(database, 'demo_worker' if worker else 'demo_request', port, batch), stdout=log, stderr=log)
        self.processes.append((process, log))
        if not wait:
            return process, port
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f'application exited: {path}: {path.read_text()[-3000:]}')
            if worker:
                if 'schema-worker-ready' in path.read_text():
                    return process, port
            else:
                try:
                    if http_request(port, 'GET', '/health')[0] == 'ready':
                        return process, port
                except (OSError, ValueError, RuntimeError):
                    pass
            time.sleep(.05)
        raise RuntimeError(f'application readiness deadline: {path}')

    def stop(self, process, kill=False):
        process.kill() if kill else process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
        for item in self.processes[:]:
            if item[0] is process:
                item[1].close()
                self.processes.remove(item)

    def stop_all(self):
        owned = self.processes[:]
        for process, _ in owned:
            if process.poll() is None:
                process.terminate()
        deadline = time.monotonic() + 5
        for process, log in owned:
            try:
                process.wait(timeout=max(.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
            log.close()
            self.processes.remove((process, log))

    def close(self):
        if self.closed:
            return
        self.stop_all()
        command(['pg_ctl', '-D', self.data, '-m', 'immediate', '-w', 'stop'], timeout=15, check=False)
        if (self.data / 'postmaster.pid').exists():
            raise RuntimeError(f'private PostgreSQL did not stop; retained data at {self.data}')
        if self.data.exists() and not self.retain_data:
            shutil.rmtree(self.data)
        shutil.rmtree(self.socket)
        self.closed = True


def http_request(port, method, path, connection=None):
    own = connection is None
    connection = connection or http.client.HTTPConnection('127.0.0.1', port, timeout=30)
    try:
        start = time.perf_counter_ns()
        connection.request(method, path)
        response = connection.getresponse()
        body = response.read()
        elapsed = time.perf_counter_ns() - start
        if response.status != 200:
            raise RuntimeError(f'{response.status} {body[:500]!r}')
        return json.loads(body), elapsed
    finally:
        if own:
            connection.close()


def row_value(row, version):
    return row['metadata']['oldText' if version == 1 else 'message']


def validate_row(rows, identity, version, expected=None):
    if len(rows) != 1 or rows[0]['id'] != identity:
        raise RuntimeError(f'wrong selected row: {rows!r}')
    row = rows[0]
    if row['author' if version == 1 else 'owner'] != 'original-owner' or row['memo'] != 'retained-memo' or row['title'] != identity:
        raise RuntimeError(f'identity or retained fields changed: {row!r}')
    if version == 2 and row['metadata']['detail'] not in ('migrated-v2', 'writer-v2'):
        raise RuntimeError(f'wrong converted payload: {row!r}')
    value = row_value(row, version)
    if expected is not None and value != expected:
        raise RuntimeError(f'lost acknowledged write: {value!r} != {expected!r}')
    return value


class Load:
    def __init__(self, port, version, clients, label, phase, *, offset=1, transaction='write'):
        self.stop_event = threading.Event()
        self.observations = []
        self.failures = []
        self.final = {}
        self.label = label
        self.started = time.monotonic()
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=clients)

        def run(client):
            identity = f'r{offset + client:012d}'
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
            expected = None
            sequence = 0
            try:
                while not self.stop_event.is_set():
                    for operation in ('read', transaction):
                        value = f'{label}-{client}-{sequence}'
                        method = 'GET' if operation == 'read' else ('PUT' if operation == 'write' else 'POST')
                        path = f'/row/{identity}' if operation == 'read' else f'/{"row" if operation == "write" else operation}/{identity}/{value}'
                        began = time.monotonic()
                        sample = {'at': time.time(), 'monotonicAt': began, 'phase': phase(), 'client': client, 'binaryVersion': version,
                                  'label': label, 'operation': operation, 'warmup': sequence < 20,
                                  'ok': False, 'elapsedNs': 0}
                        try:
                            response, elapsed = http_request(port, method, path, connection)
                            sample['elapsedNs'] = elapsed
                            if operation == 'read':
                                expected = validate_row(response, identity, version, expected)
                            else:
                                if response != value:
                                    raise RuntimeError('wrong acknowledgement')
                                expected = value
                            sample['ok'] = True
                        except Exception as error:
                            sample['elapsedNs'] = max(sample['elapsedNs'], int((time.monotonic() - began) * 1e9))
                            sample['error'] = str(error)
                            self.failures.append(sample)
                            self.stop_event.set()
                        self.observations.append(sample)
                        if self.stop_event.is_set():
                            break
                    sequence += 1
                if not self.failures and expected is not None:
                    validate_row(http_request(port, 'GET', f'/row/{identity}', connection)[0], identity, version, expected)
                    self.final[identity] = expected
            except Exception as error:
                self.failures.append({'error': str(error), 'client': client})
                self.stop_event.set()
            finally:
                connection.close()

        self.futures = [self.pool.submit(run, client) for client in range(clients)]

    def stop(self):
        self.stop_event.set()
        self.pool.shutdown(wait=True)
        for future in self.futures:
            future.result()
        elapsed = time.monotonic() - self.started
        return {'label': self.label, 'elapsedSeconds': elapsed,
                'requestsPerSecond': len(self.observations) / elapsed,
                'failures': self.failures, 'finalAcknowledgedValues': self.final,
                'observations': self.observations}


class Observer:
    def __init__(self, cluster, database, output, interval=.002):
        self.event = threading.Event()
        self.samples = []
        self.errors = []
        self.connection = SQL(dict(cluster.env, PGDATABASE=database), output / 'lock-observer.log')

        def run():
            try:
                while not self.event.is_set():
                    row = json.loads(self.connection.query("json_build_object('at',extract(epoch from clock_timestamp()),'locks',(select coalesce(json_agg(json_build_object('pid',l.pid,'type',l.locktype,'mode',l.mode,'granted',l.granted,'relation',coalesce(c.relname,''),'database',l.database::text,'relationOid',l.relation::text,'classId',l.classid::text,'objectId',l.objid::text,'objectSubId',l.objsubid,'application',a.application_name)),'[]') from pg_locks l join pg_stat_activity a on a.pid=l.pid left join pg_class c on c.oid=l.relation where a.datname=current_database() and a.application_name like 'tesl-exec:%' and ((l.locktype='relation' and l.mode in ('AccessExclusiveLock','ShareUpdateExclusiveLock','ShareLock')) or (l.locktype='advisory' and l.mode='ExclusiveLock'))),'indexes',(select coalesce(json_agg(json_build_object('pid',pid,'phase',phase,'blocksDone',blocks_done,'blocksTotal',blocks_total)),'[]') from pg_stat_progress_create_index where datname=current_database()))"))
                    self.samples.append(row)
                    self.event.wait(interval)
            except Exception as error:
                self.errors.append(str(error))

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def stop(self):
        self.event.set()
        self.thread.join(timeout=10)
        if self.thread.is_alive():
            raise RuntimeError('lock observer did not stop')
        self.connection.close()
        if self.errors:
            raise RuntimeError(str(self.errors))
        gaps = [b['at'] - a['at'] for a, b in zip(self.samples, self.samples[1:])]
        intervals = {}
        open_intervals = {}
        for sample in self.samples:
            present = {(lock['pid'], lock['type'], lock['mode'], lock['database'], lock['relationOid'], lock['classId'], lock['objectId'], lock['objectSubId'], lock['granted']) for lock in sample['locks']}
            for key in list(open_intervals):
                if key not in present:
                    started, last = open_intervals.pop(key)
                    intervals.setdefault(str(key), []).append({'firstObserved': started, 'lastObserved': last,
                                                              'observedSpanSeconds': last - started,
                                                              'releaseObservedBy': sample['at']})
            for key in present:
                started = open_intervals.get(key, (sample['at'], sample['at']))[0]
                open_intervals[key] = started, sample['at']
        for key, (started, last) in open_intervals.items():
            intervals.setdefault(str(key), []).append({'firstObserved': started, 'lastObserved': last,
                                                      'observedSpanSeconds': last - started, 'stillHeldAtLastSample': True})
        return {'samples': self.samples, 'sampleCount': len(self.samples),
                'maximumSampleGapSeconds': max(gaps, default=None), 'intervals': intervals,
                'interpretation': 'sampled spans, not exact continuous hold durations; short locks and release/reacquisition between polls may be missed'}

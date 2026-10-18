#!/usr/bin/env python3
"""Small, sequential format5 HTTP regression gate; Python standard library only."""
import argparse
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import random
import runpy
import shutil
import signal
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
# Deliberately pinned: changing this is a reviewed comparison-policy change.
BASELINE = '9852f263b0ce52f78045c3edb266625aa4460674'
PAIRS, CALIBRATION_PAIRS, SAMPLES, WARMUP = 8, 6, 1000, 200
RELATIVE = .50
FLOOR_NS = {'p50': 500_000, 'p95': 2_000_000}


def run(args, *, cwd=None, env=None, timeout=1800):
    result = subprocess.run(list(map(str, args)), cwd=cwd, env=env,
                            capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{args}:\n{result.stdout}\n{result.stderr}')
    return result.stdout.strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(root):
    files = {str(p.relative_to(root)): digest(p) for p in sorted(root.rglob('*')) if p.is_file()}
    return {'sha256': hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest(), 'files': files}


def candidate_paths(root, output):
    """Snapshot Git-visible sources without copying this run's own evidence."""
    paths = subprocess.check_output(
        ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root).split(b'\0')
    for encoded in sorted(set(paths) - {b''}):
        relative = Path(os.fsdecode(encoded))
        source = root / relative
        if source == output or output in source.parents:
            continue
        if source.is_file():
            yield relative


def percentile(values, q):
    return sorted(values)[max(0, math.ceil(len(values) * q) - 1)]


def compare(pairs, samples=SAMPLES):
    """Resample whole pairs, not correlated requests; deterministic 99% upper bound."""
    if len(pairs) < 6:
        raise ValueError('at least six complete pairs required')
    for pair in pairs:
        if len(pair) != 2:
            raise ValueError('incomplete pair')
        for side in pair:
            for operation in ('read', 'write'):
                values = side[operation]
                if len(values) != samples or any(type(v) is not int or v <= 0 for v in values):
                    raise ValueError('missing or invalid raw observations')
    result = {}
    for operation in ('read', 'write'):
        result[operation] = {}
        for name, q in (('p50', .5), ('p95', .95)):
            a = [percentile(p[0][operation], q) for p in pairs]
            b = [percentile(p[1][operation], q) for p in pairs]
            differences = [y - x for x, y in zip(a, b)]
            rng = random.Random(9852)
            upper = percentile([statistics.median(rng.choices(differences, k=len(pairs)))
                                for _ in range(4000)], .99)
            base = statistics.median(a)
            limit = max(FLOOR_NS[name], RELATIVE * base)
            result[operation][name] = dict(baseline_ns=base, candidate_ns=statistics.median(b),
                paired_delta_ns=statistics.median(differences), upper99_delta_ns=upper,
                limit_ns=limit, passed=upper <= limit)
    return result


def calibrated(pairs, samples=SAMPLES):
    # Two-sided A/A variability must fit HALF the regression allowance. A noisy
    # host fails calibration; it never earns a larger threshold or automatic pass.
    forward, reverse = compare(pairs, samples), compare([(b, a) for a, b in pairs], samples)
    return {op: {q: {'noise_ns': max(0, forward[op][q]['upper99_delta_ns'],
                                     reverse[op][q]['upper99_delta_ns']),
                         'budget_ns': forward[op][q]['limit_ns'] / 2}
                 for q in ('p50', 'p95')} for op in ('read', 'write')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-ref', default=os.environ.get('TESL_MIGRATION_LATENCY_BASELINE', BASELINE))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if output == ROOT or output in ROOT.parents:
        parser.error('--output must not contain the source checkout')
    output.mkdir(parents=True, exist_ok=False)
    def interrupted(signum, frame):
        raise InterruptedError(f'interrupted by signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    evidence = {'status': 'incomplete', 'baseline_ref': args.baseline_ref,
                'policy': {'relative': RELATIVE, 'floor_ns': FLOOR_NS, 'pairs': PAIRS,
                           'calibration_pairs': CALIBRATION_PAIRS, 'samples': SAMPLES,
                           'warmup': WARMUP, 'rows': 3, 'concurrency': 1},
                'scope': 'steady-state format5 V1 HTTP read/update regression, not absolute overhead'}
    cluster = None
    processes = []
    raw = open(output / 'raw.jsonl', 'x', buffering=1)
    try:
        for tool in ('git', 'tar', 'dune', 'go', 'initdb', 'pg_ctl', 'psql'):
            if not shutil.which(tool):
                raise RuntimeError(f'required tool missing: {tool}')
        baseline = run(['git', 'rev-parse', '--verify', args.baseline_ref + '^{commit}'], cwd=ROOT)
        evidence['baseline_commit'] = baseline
        evidence['candidate_commit'] = run(['git', 'rev-parse', 'HEAD'], cwd=ROOT)
        evidence['candidate_status'] = run(['git', 'status', '--porcelain'], cwd=ROOT)
        evidence['tools'] = {tool: run(command) for tool, command in {
            'go': ['go', 'version'], 'dune': ['dune', '--version'],
            'postgres': ['pg_ctl', '--version']}.items()}
        evidence['host'] = dict(zip(('system', 'node', 'release', 'version', 'machine'), os.uname()))
        a, b = output / 'baseline', output / 'candidate'
        a.mkdir(); b.mkdir()
        archive = output / 'baseline.tar'
        run(['git', 'archive', '--format=tar', '-o', archive, baseline], cwd=ROOT)
        run(['tar', '-xf', archive, '-C', a])
        for relative in candidate_paths(ROOT, output):
            source = ROOT / relative
            target = b / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        evidence['sources'] = {label: inventory(repo) for label, repo in (('baseline', a), ('candidate', b))}
        fixture = b / 'example/db-three-upgrades'
        fixture_files = ('app.tesl', 'tesl.toml', 'schema/notes/v-current.tesl')
        evidence['fixture'] = {f: digest(fixture / f) for f in fixture_files}
        apps = {}
        for label, repo in (('baseline', a), ('candidate', b)):
            env = dict(os.environ, TESL_REPO_ROOT=str(repo), GOWORK='off')
            run(['dune', 'build', '--root', repo / 'compiler', '-j', os.environ.get('TESL_CI_JOBS', '2'),
                 'bin/main.exe'], env=env)
            source = output / (label + '-source')
            for f in fixture_files:
                target = source / f
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(fixture / f, target)
            compiler = repo / 'compiler/_build/default/bin/main.exe'
            evidence.setdefault('compilers', {})[label] = digest(compiler)
            for f in source.rglob('*.tesl'):
                check = json.loads(run([compiler, 'agent-context', f], env=env))
                if not check['ok']:
                    raise RuntimeError(str(check))
            generated = output / (label + '-go')
            run([compiler, '--backend', 'go', source / 'app.tesl', '--out', generated], env=env)
            apps[label] = output / (label + '-app')
            run(['go', 'build', '-o', apps[label], './cmd/app'], cwd=generated, env=env)
        evidence['binaries'] = {label: digest(app) for label, app in apps.items()}
        evidence['generated'] = {label: inventory(output / (label + '-go')) for label in ('baseline', 'candidate')}
        helpers = runpy.run_path(str(fixture / 'run.py'))
        cluster = Path(tempfile.mkdtemp(prefix='tesl-lat-', dir='/tmp'))
        data = output / 'postgres-data'
        run(['initdb', '-D', data, '-U', 'demo_installer', '--auth=trust', '--no-locale', '--encoding=UTF8'])
        run(['pg_ctl', '-D', data, '-l', output / 'postgres.log', '-o', f"-k {cluster} -h ''", '-w', 'start'])
        pg = dict(os.environ, PGHOST=str(cluster), PGPORT='5432', PGUSER='demo_installer', PGDATABASE='postgres')

        def sql(db, statement):
            return run(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-Atc', statement], env=dict(pg, PGDATABASE=db), timeout=60)

        sql('postgres', 'create role demo_owner nologin; create role demo_worker login; create role demo_request login')

        def stop(proc, log):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    proc.kill(); proc.wait(timeout=10)
            log.close()

        def sample(label, phase, pair, position):
            db = f'lat_{phase}_{pair}_{position}'
            sql('postgres', f'create database {db}')
            sql('postgres', f'grant create on database {db} to demo_owner')
            sql(db, 'grant create on schema public to demo_owner')
            port = helpers['port']()

            def appenv(role):
                return dict(os.environ, DEMO_HOST=str(cluster), DEMO_PORT='5432', DEMO_DB=db,
                    DEMO_OWNER='demo_owner', DEMO_WORKER='demo_worker', DEMO_REQUEST='demo_request',
                    DEMO_USER=role, DEMO_HTTP_PORT=str(port),
                    DEMO_DDL=f'host={cluster} dbname={db} user={role}')

            run([apps[label], '--schema', 'install', '--worker', 'demo_worker', '--request', 'demo_request', '--json'], env=appenv('demo_installer'), timeout=60)
            local = []
            connection = None
            try:
                for role, extra in (('demo_worker', ['--schema', 'worker', '--json']), ('demo_request', [])):
                    log = open(output / f'{db}-{role}.log', 'w')
                    proc = subprocess.Popen([str(apps[label]), *extra], env=appenv(role), stdout=log, stderr=log)
                    processes.append((proc, log)); local.append((proc, log))
                    def ready():
                        if proc.poll() is not None:
                            raise RuntimeError(f'{role} exited; see {log.name}')
                        if extra:
                            return 'schema-worker-ready' in Path(log.name).read_text()
                        return helpers['request'](port, 'GET', '/health') == 'ready'
                    helpers['eventually'](ready)
                if sql(db, 'select format_version from notes.tesl_schema_meta where id=1') != '5':
                    raise RuntimeError('benchmark requires actual format5')
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)

                def request(method, path):
                    start = time.perf_counter_ns()
                    connection.request(method, path)
                    response = connection.getresponse()
                    body = response.read()
                    elapsed = time.perf_counter_ns() - start
                    if response.status != 200:
                        raise RuntimeError(f'{method} {path}: {response.status} {body!r}')
                    return json.loads(body), elapsed

                for path in ('/seed', '/late', '/current'):
                    if request('POST', path)[0] != 'created':
                        raise RuntimeError('seed failed')
                samples = {'read': [], 'write': []}
                expected = 'kept'

                def validate(rows):
                    if len(rows) != 3 or {r['id'] for r in rows} != {'one', 'late', 'current'}:
                        raise RuntimeError('wrong row set')
                    for row in rows:
                        text = expected if row['id'] == 'one' else row['id']
                        if row['metadata'] != {'oldText': text} or row['author'] != 'original-owner' or row['memo'] != 'retained-memo' or row['title'] != ('kept' if row['id'] == 'one' else row['id']):
                            raise RuntimeError(f'incorrect stored row: {row}')

                for i in range(WARMUP + SAMPLES):
                    rows, read_ns = request('GET', '/notes')
                    validate(rows)
                    expected = 'edited' if i % 2 == 0 else 'repaired'
                    value, write_ns = request('PUT', '/edit' if i % 2 == 0 else '/repair')
                    if value != expected:
                        raise RuntimeError('write acknowledgement incorrect')
                    validate(request('GET', '/notes')[0])
                    raw.write(json.dumps(dict(phase=phase, pair=pair, position=position, revision=label,
                        index=i, warmup=i < WARMUP, read_ns=read_ns, write_ns=write_ns, correct=True)) + '\n')
                    if i >= WARMUP:
                        samples['read'].append(read_ns); samples['write'].append(write_ns)
                if any(proc.poll() is not None for proc, _ in local):
                    raise RuntimeError('application or worker died during sample')
                return samples
            finally:
                if connection:
                    connection.close()
                for proc, log in reversed(local):
                    stop(proc, log)
                    processes.remove((proc, log))
                sql('postgres', f'drop database {db}')

        calibration = []
        for i in range(CALIBRATION_PAIRS):
            calibration.append((sample('baseline', 'calibration', i, 0), sample('baseline', 'calibration', i, 1)))
        evidence['calibration'] = calibrated(calibration)
        if any(v['noise_ns'] > v['budget_ns'] for op in evidence['calibration'].values() for v in op.values()):
            raise RuntimeError('A/A calibration too noisy; no regression verdict')
        pairs = []
        for i in range(PAIRS):
            order = ('baseline', 'candidate') if i % 2 == 0 else ('candidate', 'baseline')
            values = {label: sample(label, 'comparison', i, position) for position, label in enumerate(order)}
            pairs.append((values['baseline'], values['candidate']))
        evidence['comparison'] = compare(pairs)
        if not all(v['passed'] for op in evidence['comparison'].values() for v in op.values()):
            raise RuntimeError('latency regression or insufficient evidence below regression limit')
        evidence['status'] = 'passed'
        evidence['errors'] = 0
    except BaseException as error:
        evidence['status'] = 'failed'
        evidence['error'] = str(error)
        raise
    finally:
        raw.close()
        for proc, log in reversed(processes):
            proc.kill(); proc.wait(); log.close()
        if cluster:
            subprocess.run(['pg_ctl', '-D', str(output / 'postgres-data'), '-m', 'immediate', '-w', 'stop'], capture_output=True)
            shutil.rmtree(cluster)
        (output / 'result.json').write_text(json.dumps(evidence, indent=2) + '\n')
        # Sources, emitted trees, application binaries and raw evidence remain.
        # Dune scratch is reproducible and can otherwise exhaust a CI runner.
        for label in ('baseline', 'candidate'):
            build = output / label / 'compiler/_build'
            if build.is_dir():
                shutil.rmtree(build)


if __name__ == '__main__':
    main()

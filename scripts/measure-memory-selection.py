#!/usr/bin/env python3
"""Compile and measure bounded Memory queries through real HTTP requests.

Use alternating baseline/candidate --repo-root values with the same fixture.
Seeding uses the actual insertMany path and is outside query timings. Every
response is compared with an independently computed ordered result. Descriptive
samples only: this does not replace an acceptance gate or establish a p99 SLA.
"""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo-root', type=Path, default=ROOT)
    parser.add_argument('--fixture', type=Path, default=ROOT / 'bench/BoundedMemory.tesl')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--rows', type=int, default=20000)
    parser.add_argument('--samples', type=int, default=30)
    parser.add_argument('--warmup', type=int, default=5)
    args = parser.parse_args()
    if not 100 <= args.rows <= 30000 or args.samples < 1 or args.warmup < 1:
        parser.error('rows must be 100..30000; samples and warmup must be positive')
    repo, output = args.repo_root.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = output / 'BoundedMemory.tesl'
    source.write_bytes(args.fixture.read_bytes())
    env = dict(os.environ, TESL_REPO_ROOT=str(repo), GOWORK='off', BENCH_ROWS=str(args.rows))
    compiler = repo / 'compiler/_build/default/bin/main.exe'
    evidence = {'status': 'incomplete', 'rows': args.rows, 'warmup': args.warmup, 'samples': args.samples,
                'sourceSha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'observations': []}
    process, connection, log = None, None, None

    def command(arguments, cwd=None):
        result = subprocess.run(list(map(str, arguments)), cwd=cwd, env=env, text=True,
                                capture_output=True, timeout=300)
        if result.returncode:
            raise RuntimeError(f'{arguments}:\n{result.stdout}\n{result.stderr}')
        return result.stdout

    def request(method, path):
        started = time.perf_counter_ns()
        connection.request(method, path)
        response = connection.getresponse()
        raw = response.read()
        if response.status != 200:
            raise RuntimeError(f'{method} {path}: {response.status}: {raw!r}')
        return json.loads(raw), time.perf_counter_ns() - started

    try:
        checked = json.loads(command([compiler, 'agent-context', source]))
        if not checked['ok']:
            raise RuntimeError(json.dumps(checked))
        command([compiler, '--backend', 'go', source, '--out', output / 'go'])
        command(['go', 'build', '-o', output / 'app', './cmd/app'], cwd=output / 'go')
        evidence['compilerSha256'] = hashlib.sha256(compiler.read_bytes()).hexdigest()
        evidence['binarySha256'] = hashlib.sha256((output / 'app').read_bytes()).hexdigest()
        evidence['goVersion'] = command(['go', 'version']).strip()
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        log = (output / 'server.log').open('w')
        process = subprocess.Popen([str(output / 'app')], env=dict(env, PORT=str(port)), stdout=log, stderr=log)
        deadline = time.monotonic() + 30
        while True:
            if process.poll() is not None:
                raise RuntimeError('server exited before readiness')
            try:
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=180)
                if request('GET', '/health')[0] == 'ready':
                    break
            except OSError:
                connection.close()
            if time.monotonic() >= deadline:
                raise RuntimeError('server did not become ready')
            time.sleep(.02)
        seeded, evidence['seed_ns'] = request('POST', '/seed')
        if seeded != args.rows:
            raise RuntimeError('seeding did not insert the requested rows')
        rows = [{'id': index, 'score': (index * 48271 + 17) % 100003,
                 'label': 'item', 'groupName': 'group', 'note': 'retained', 'owner': 'owner', 'metadata': 'metadata'}
                for index in range(args.rows)]
        ascending = sorted(rows, key=lambda row: row['score'])
        descending = sorted(rows, key=lambda row: -row['score'])
        expected = {'/top': ascending[:10], '/page': descending[20:30],
                    '/first': ascending[0]['id'], '/plain': rows[20:30]}
        for iteration in range(args.warmup + args.samples):
            for path, want in expected.items():
                actual, elapsed = request('GET', path)
                if actual != want:
                    raise RuntimeError(f'{path}: incorrect rows, ordering or untouched fields')
                evidence['observations'].append({'iteration': iteration, 'path': path, 'ns': elapsed,
                                                 'warmup': iteration < args.warmup, 'correct': True})
        evidence['median_ms'] = {path: statistics.median(item['ns'] for item in evidence['observations']
                                                       if item['path'] == path and not item['warmup']) / 1e6
                                 for path in expected}
        evidence['status'] = 'correctness-passed'
        print(json.dumps({'status': evidence['status'], 'rows': args.rows, 'median_ms': evidence['median_ms']}), flush=True)
    except BaseException as error:
        evidence['status'], evidence['error'] = 'failed', str(error)
        raise
    finally:
        if connection:
            connection.close()
        if process:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if log:
            log.close()
        (output / 'result.json').write_text(json.dumps(evidence, indent=2) + '\n')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Measure real HTTP insertMany with primary/composite-unique checks and rollback.

Run identical fixtures with alternating baseline/candidate --repo-root values.
Dataset construction and map setup are INCLUDED in request timing. Reset and
independent validation are outside timing. No acceptance thresholds are changed.
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
    parser.add_argument('--fixture', type=Path, default=ROOT / 'bench/InsertManyMemory.tesl')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--rows', type=int, nargs='+', default=[1, 1000, 8000])
    parser.add_argument('--samples', type=int, default=8)
    parser.add_argument('--warmup', type=int, default=2)
    args = parser.parse_args()
    if args.samples < 1 or args.warmup < 1 or any(n < 1 or n > 10000 for n in args.rows):
        parser.error('positive samples/warmup and rows from 1 to 10000 required')
    repo, output = args.repo_root.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = output / 'InsertManyMemory.tesl'
    source.write_bytes(args.fixture.read_bytes())
    compiler = repo / 'compiler/_build/default/bin/main.exe'
    env = dict(os.environ, TESL_REPO_ROOT=str(repo), GOWORK='off')
    evidence = {'status': 'incomplete', 'samples': args.samples, 'warmup': args.warmup,
                'sourceSha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'cases': []}
    process, connection, log = None, None, None

    def command(arguments, cwd=None):
        result = subprocess.run(list(map(str, arguments)), cwd=cwd, env=env, text=True,
                                capture_output=True, timeout=300)
        if result.returncode:
            raise RuntimeError(f'{arguments}:\n{result.stdout}\n{result.stderr}')
        return result.stdout

    def request(method, path, status=200):
        started = time.perf_counter_ns()
        connection.request(method, path)
        response = connection.getresponse()
        raw = response.read()
        elapsed = time.perf_counter_ns() - started
        if response.status != status:
            raise RuntimeError(f'{method} {path}: expected {status}, got {response.status}: {raw!r}')
        return (json.loads(raw) if status == 200 else None), elapsed

    def stop():
        nonlocal process, connection, log
        if connection:
            connection.close()
            connection = None
        if process:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            process = None
        if log:
            log.close()
            log = None

    try:
        checked = json.loads(command([compiler, 'agent-context', source]))
        if not checked['ok']:
            raise RuntimeError(json.dumps(checked))
        command([compiler, '--backend', 'go', source, '--out', output / 'go'])
        command(['go', 'build', '-o', output / 'app', './cmd/app'], cwd=output / 'go')
        evidence['compilerSha256'] = hashlib.sha256(compiler.read_bytes()).hexdigest()
        evidence['binarySha256'] = hashlib.sha256((output / 'app').read_bytes()).hexdigest()
        evidence['goVersion'] = command(['go', 'version']).strip()
        for count in args.rows:
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                port = listener.getsockname()[1]
            log = (output / f'server-{count}.log').open('w')
            process = subprocess.Popen([str(output / 'app')], env=dict(env, PORT=str(port), BENCH_ROWS=str(count)),
                                       stdout=log, stderr=log)
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
            expected = [{'id': index, 'code': index, 'category': 'group', 'label': 'retained'} for index in range(count)]
            case = {'rows': count, 'observations': []}
            evidence['cases'].append(case)
            for iteration in range(args.warmup + args.samples):
                for path in ('/bulk', '/transaction'):
                    if request('POST', '/reset')[0] != 0:
                        raise RuntimeError('reset did not empty table')
                    inserted, elapsed = request('POST', path)
                    if inserted != count or request('GET', '/items')[0] != expected:
                        raise RuntimeError('insert lost identities, fields, or insertion order')
                    case['observations'].append({'iteration': iteration, 'path': path, 'ns': elapsed,
                                                 'warmup': iteration < args.warmup, 'correct': True})
                    (output / 'result.json').write_text(json.dumps(evidence, indent=2) + '\n')
            # A late duplicate preserves the successful prefix outside a txn,
            # but restores the initial state inside one. Retry must remain valid.
            for path, wanted in (('/duplicate', expected), ('/transaction-duplicate', [])):
                request('POST', '/reset')
                request('POST', path, 500)
                if request('GET', '/items')[0] != wanted:
                    raise RuntimeError(f'{path}: incorrect duplicate/rollback publication')
            if request('POST', '/transaction')[0] != count or request('GET', '/items')[0] != expected:
                raise RuntimeError('reinsertion after rollback failed')
            case['duplicate_and_rollback_verified'] = True
            case['median_ms'] = {path: statistics.median(item['ns'] for item in case['observations']
                                                       if item['path'] == path and not item['warmup']) / 1e6
                                 for path in ('/bulk', '/transaction')}
            print(json.dumps({'rows': count, 'median_ms': case['median_ms'], 'correct': True}), flush=True)
            stop()
        evidence['status'] = 'correctness-passed'
    except BaseException as error:
        evidence['status'], evidence['error'] = 'failed', str(error)
        raise
    finally:
        stop()
        (output / 'result.json').write_text(json.dumps(evidence, indent=2) + '\n')


if __name__ == '__main__':
    main()

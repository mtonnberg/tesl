#!/usr/bin/env python3
"""Compare two ordinary V4 db-three-upgrades binaries on a private database.

This is a small steady-state contention experiment, not the release-scale
performance acceptance gate. Both binaries must use the same generated V4 app,
schema, history and build options. It does not build or modify either binary.
"""
import argparse
import concurrent.futures
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import shutil
import socket
import statistics
import subprocess
import tempfile
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def quantile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--pairs', type=int, default=3)
    parser.add_argument('--samples-per-client', type=int, default=80)
    args = parser.parse_args()
    if args.pairs < 1 or args.samples_per_client < 1:
        parser.error('pairs and samples-per-client must be positive')
    binaries = {'before': args.before.resolve(), 'after': args.after.resolve()}
    hashes = {label: digest(binary) for label, binary in binaries.items()}
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    data = output / 'postgres-data'
    sockets = Path(tempfile.mkdtemp(prefix='tesl-contention-', dir='/tmp'))
    environment = dict(os.environ)
    postgres = dict(environment, PGHOST=str(sockets), PGPORT='5432',
                    PGUSER='demo_installer', PGDATABASE='postgres')
    processes = []
    expected_body = 'kept'
    evidence = {
        'status': 'incomplete', 'binary_sha256': hashes,
        'scope': 'steady-state V4 format5, four-release row history, three rows; not PR-base overhead or release-scale acceptance',
        'host': dict(zip(('system', 'node', 'release', 'version', 'machine'), os.uname())),
        'pairs': args.pairs, 'warmup_per_client': 20,
        'quantile_method': 'nearest rank: ceiling(sample count * fraction)',
        'samples_per_client': args.samples_per_client, 'results': [],
    }

    def command(arguments, env=None, timeout=180):
        result = subprocess.run(list(map(str, arguments)), env=env or environment,
                                capture_output=True, text=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(f'{arguments}: {result.returncode}\n{result.stdout}\n{result.stderr}')
        return result.stdout.strip()

    def sql(statement, database='postgres'):
        return command(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-Atc', statement],
                       dict(postgres, PGDATABASE=database))

    def app_environment(port):
        return dict(environment, DEMO_HOST=str(sockets), DEMO_PORT='5432',
                    DEMO_DB='latency', DEMO_USER='demo_request', DEMO_OWNER='demo_owner',
                    DEMO_WORKER='demo_worker', DEMO_REQUEST='demo_request',
                    DEMO_HTTP_PORT=str(port),
                    DEMO_DDL=f'host={sockets} dbname=latency user=demo_worker',
                    TESL_SCHEMA_INSTALLER_DSN=f'host={sockets} dbname=latency user=demo_installer',
                    TESL_SCHEMA_DEPLOY_TIMEOUT_SECONDS='120')

    def request(connection, method, path):
        started = time.perf_counter_ns()
        connection.request(method, path)
        response = connection.getresponse()
        body = response.read()
        elapsed = time.perf_counter_ns() - started
        if response.status != 200:
            raise RuntimeError(f'{method} {path}: {response.status} {body!r}')
        return json.loads(body), elapsed

    def validate_rows(rows):
        if len(rows) != 3 or {row['id'] for row in rows} != {'one', 'late', 'current'}:
            raise RuntimeError(f'incorrect row set: {rows!r}')
        for row in rows:
            body = expected_body if row['id'] == 'one' else row['id']
            title = 'kept' if row['id'] == 'one' else row['id']
            if (row['metadata'] != {'body': body, 'origin': 'writer-v3', 'revision': 3}
                    or row['owner'] != 'writer-v4' or row['title'] != title):
                raise RuntimeError(f'incorrect stored row: {row!r}')

    def stop(process, log):
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
        log.close()
        processes.remove((process, log))

    def serve(label):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        log = (output / f'{label}-{time.time_ns()}.log').open('w')
        process = subprocess.Popen([str(binaries[label])], env=app_environment(port),
                                   stdout=log, stderr=log)
        processes.append((process, log))
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f'application exited; see {log.name}')
            try:
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=1)
                try:
                    value, _ = request(connection, 'GET', '/health')
                    if value == 'ready':
                        return process, port, log
                finally:
                    connection.close()
            except (OSError, ValueError):
                pass
            time.sleep(.1)
        raise RuntimeError('readiness deadline expired')

    def measure(port, clients, method, path):
        def client(_):
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
            observations = []
            try:
                for index in range(20 + args.samples_per_client):
                    value, elapsed = request(connection, method, path)
                    if method == 'GET':
                        validate_rows(value)
                    elif value != 'edited':
                        raise RuntimeError(f'incorrect write acknowledgement: {value!r}')
                    if index >= 20:
                        observations.append(elapsed)
            finally:
                connection.close()
            return observations

        started = time.perf_counter()
        with concurrent.futures.ThreadPoolExecutor(max_workers=clients) as pool:
            observations = sum(pool.map(client, range(clients)), [])
        return {'concurrency': clients, 'method': method, 'samples': len(observations),
                'p50_ms': quantile(observations, .5) / 1e6,
                'p95_ms': quantile(observations, .95) / 1e6,
                'p99_ms': quantile(observations, .99) / 1e6,
                'mean_ms': statistics.mean(observations) / 1e6,
                'wall_s': time.perf_counter() - started, 'raw_ns': observations}

    try:
        evidence['tools'] = {tool: command(arguments) for tool, arguments in {
            'postgres': ['pg_ctl', '--version'], 'go': ['go', 'version']}.items()}
        command(['initdb', '-D', data, '-U', 'demo_installer', '--auth=trust',
                 '--no-locale', '--encoding=UTF8'])
        command(['pg_ctl', '-D', data, '-l', output / 'postgres.log', '-o',
                 f"-k {sockets} -h '' -c max_connections=100 -c track_functions=all", '-w', 'start'])
        sql('create role demo_owner nologin; create role demo_worker login; create role demo_request login')
        sql('create database latency')
        sql('grant create on database latency to demo_owner')
        sql('grant create on schema public to demo_owner', 'latency')
        started = time.perf_counter()
        evidence['deployment'] = json.loads(command(
            [binaries['before'], '--schema', 'deploy', '--json'], app_environment(0)))
        evidence['deployment_seconds'] = time.perf_counter() - started
        process, port, log = serve('before')
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
        try:
            for path in ('/seed', '/late', '/current'):
                if request(connection, 'POST', path)[0] != 'created':
                    raise RuntimeError('seed failed')
            validate_rows(request(connection, 'GET', '/notes')[0])
        finally:
            connection.close()
        stop(process, log)
        for pair in range(args.pairs):
            order = ('before', 'after') if pair % 2 == 0 else ('after', 'before')
            for label in order:
                process, port, log = serve(label)
                for clients, method, path in ((1, 'GET', '/notes'), (8, 'GET', '/notes'),
                                              (32, 'GET', '/notes'), (1, 'PUT', '/edit')):
                    result = measure(port, clients, method, path)
                    result.update(pair=pair, variant=label)
                    evidence['results'].append(result)
                    print(json.dumps({k: v for k, v in result.items() if k != 'raw_ns'}), flush=True)
                expected_body = 'edited'
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
                try:
                    validate_rows(request(connection, 'GET', '/notes')[0])
                finally:
                    connection.close()
                stop(process, log)
        if {label: digest(binary) for label, binary in binaries.items()} != hashes:
            raise RuntimeError('a measured binary changed during the experiment')
        evidence['postgres_function_totals'] = sql(
            'select schemaname,funcname,calls,total_time,self_time from pg_stat_user_functions order by self_time desc limit 20',
            'latency')
        evidence['status'] = 'passed'
    except BaseException as error:
        evidence['status'] = 'failed'
        evidence['error'] = str(error)
        raise
    finally:
        for process, log in processes:
            process.kill()
            process.wait(timeout=10)
            log.close()
        subprocess.run(['pg_ctl', '-D', str(data), '-m', 'immediate', '-w', 'stop'],
                       env=environment, capture_output=True)
        shutil.rmtree(sockets)
        (output / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')


if __name__ == '__main__':
    main()

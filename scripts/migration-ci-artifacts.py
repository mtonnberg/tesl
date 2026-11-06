#!/usr/bin/env python3
"""Build once, verify and reuse source-bound migration fixtures across PG majors."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = 'manifest.json'
FAMILIES = {
    'row': ('example/db-three-upgrades/run.py', 'review05-releases/row'),
    'queue': ('example/queue-three-upgrades/run.py', 'review05-releases/queue'),
    'twenty': ('example/db-twenty-releases/run.py', 'twenty-releases'),
}


def run(args, **kwargs):
    return subprocess.check_output(list(map(str, args)), text=True, **kwargs).strip()


def digest(path):
    # Native planning runs on Ubuntu 22.04's Python 3.10, before Nix. Keep
    # hashing streaming without depending on Python 3.11's file_digest API.
    checksum = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


def source_identity(root, expected=None):
    revision = run(['git', 'rev-parse', 'HEAD'], cwd=root)
    if expected and revision != expected:
        raise ValueError('fixture build revision differs from expected revision')
    dirty = run(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=root)
    if expected and dirty:
        raise ValueError('fixture reuse requires clean tracked source in CI')
    paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).split(b'\0')
    hashes = {}
    for path in sorted(set(paths) - {b''}):
        name = os.fsdecode(path)
        file = root / name
        if file.is_symlink():
            hashes[name] = ['symlink', os.readlink(file)]
        else:
            hashes[name] = ['file', digest(file), bool(file.stat().st_mode & 0o111)]
    return {'revision': revision, 'tree': run(['git', 'rev-parse', 'HEAD^{tree}'], cwd=root),
            'tracked_clean': not dirty,
            'inputs_sha256': hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()}


def tools():
    return {'go': run(['go', 'version']), 'go_env': json.loads(run(['go', 'env', '-json',
                'GOOS', 'GOARCH', 'CGO_ENABLED', 'GOAMD64', 'GOARM64', 'GOEXPERIMENT',
                'GOFLAGS', 'CC', 'CXX', 'CGO_CFLAGS', 'CGO_CPPFLAGS', 'CGO_CXXFLAGS',
                'CGO_LDFLAGS', 'GOTOOLCHAIN'])), 'dune': run(['dune', '--version']),
            'dune_profile': os.environ.get('DUNE_PROFILE', 'dev'),
            'ocaml': run(['ocamlopt', '-version']), 'platform': platform.system(),
            'machine': platform.machine()}


def inventory(directory):
    result = {}
    for file in sorted(directory.rglob('*')):
        mode = file.lstat().st_mode
        if stat.S_ISDIR(mode):
            continue
        if not stat.S_ISREG(mode):
            raise ValueError(f'fixture artifact must contain regular files: {file}')
        result[file.relative_to(directory).as_posix()] = {
            'sha256': digest(file), 'executable': bool(mode & 0o111)}
    return result


def required_files():
    required = []
    releases = {'row': [f'v{i}' for i in range(1, 5)],
                'queue': ['v1', 'v2', 'v2-repair', 'v3', 'v3-repair', 'v4', 'v4-repair', 'v4-catchup-repair'],
                'twenty': [f'v{i}' for i in range(1, 21)]}
    for family, versions in releases.items():
        for version in versions:
            required.extend([f'{family}/{version}/app', f'{family}/{version}/source/app.tesl',
                             f'{family}/{version}/go/go.mod'])
            if family == 'twenty':
                required.extend([f'{family}/{version}/api.test', f'{family}/{version}/build.json',
                                 f'{family}/{version}/fixtures.log'])
    required.append('queue/v4/app-test')
    return required


def verify(bundle, source, toolchain):
    if bundle.is_symlink() or not (bundle / MANIFEST).is_file() or (bundle / MANIFEST).is_symlink():
        raise ValueError('fixture manifest must be a regular file in a real directory')
    manifest = json.loads((bundle / MANIFEST).read_text())
    if type(manifest.get('version')) is not int or manifest['version'] != 1 or manifest.get('source') != source or manifest.get('tools') != toolchain:
        raise ValueError('fixture source or toolchain identity differs')
    if manifest.get('families') != list(FAMILIES):
        raise ValueError('fixture family inventory differs')
    if not isinstance(manifest.get('compiler_sha256'), str) or not re.fullmatch(r'[0-9a-f]{64}', manifest['compiler_sha256']):
        raise ValueError('fixture compiler digest is missing or invalid')
    payload = bundle / 'payload'
    if payload.is_symlink() or not payload.is_dir():
        raise ValueError('fixture payload must be a real directory')
    files = inventory(payload)
    if files != manifest.get('files'):
        raise ValueError('fixture bytes, executable modes or file inventory changed')
    if not set(required_files()) <= files.keys():
        raise ValueError('fixture bundle omits required releases or test executables')
    for name in required_files():
        if name.endswith(('/app', '/api.test', '/app-test')) and not files[name]['executable']:
            raise ValueError(f'fixture executable lost its executable mode: {name}')
    if set(manifest.get('build_seconds', {})) != {'compiler', 'cache-warm', *FAMILIES}:
        raise ValueError('fixture build timing inventory is incomplete')
    if any(type(value) not in (int, float) or not math.isfinite(value) or value < 0
           for value in manifest['build_seconds'].values()):
        raise ValueError('fixture build timings must be finite nonnegative seconds')
    return manifest


def build(bundle, expected=None):
    source, toolchain = source_identity(ROOT, expected), tools()
    bundle.mkdir(parents=True, exist_ok=False)
    payload = bundle / 'payload'
    payload.mkdir()
    compiler = ROOT / 'compiler/_build/default/bin/main.exe'
    env = dict(os.environ, TESL_REPO_ROOT=str(ROOT), TESL_OCAML_COMPILER=str(compiler))
    # These fixtures run pure conversion checks here. Each consumer executes its
    # own PostgreSQL lifecycle and API assertions on its selected server major.
    for key in list(env):
        if key.startswith(('TESL_TEST_POSTGRES_SHARED_', 'TESL_MIGRATION_TEST_')):
            env.pop(key)
    timings = {}
    commands = [('compiler', ['dune', 'build', '--root', ROOT / 'compiler', '-j',
                              os.environ.get('TESL_CI_JOBS', '2'), 'bin/main.exe'])]
    commands += [(name, ['python3', ROOT / recipe, '--compiler', compiler,
                        '--build-only', '--output', payload / name])
                 for name, (recipe, _) in FAMILIES.items()]
    with tempfile.TemporaryDirectory(prefix='fixture-go-cache-', dir=bundle.parent) as cache:
        env['GOCACHE'] = cache
        started = time.monotonic()
        with (bundle / 'cache-warm.log').open('w') as log:
            for flags in ([], ['-race']):
                subprocess.run(['go', 'list', '-trimpath', '-test', '-export', '-deps', *flags,
                                '-tags=tesl_migration_test', './teslrt'], cwd=ROOT / 'runtime/go',
                               env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1800)
            subprocess.run(['python3', str(ROOT / 'scripts/migration-go-cache.py'), 'seed', cache],
                           env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        timings['cache-warm'] = time.monotonic() - started
        for name, command in commands:
            started = time.monotonic()
            with (bundle / f'{name}.log').open('w') as log:
                subprocess.run(list(map(str, command)), cwd=ROOT, env=env, stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=3600)
                subprocess.run(['python3', str(ROOT / 'scripts/migration-go-cache.py'), 'prune', cache],
                               env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            timings[name] = time.monotonic() - started
            print(f'Fixture build {name}: {timings[name]:.3f}s', flush=True)
    if source_identity(ROOT, expected) != source or tools() != toolchain:
        raise ValueError('fixture inputs changed during build')
    manifest = {'version': 1, 'source': source, 'tools': toolchain,
                'compiler_sha256': digest(compiler), 'families': list(FAMILIES),
                'build_seconds': timings, 'files': inventory(payload)}
    (bundle / MANIFEST).write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
    verify(bundle, source, toolchain)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
            stream.write('## Shared fixture build seconds\n\n```json\n' + json.dumps(timings, indent=2) + '\n```\n')


def restore(bundle, output, evidence, expected=None):
    started = time.monotonic()
    source, toolchain = source_identity(ROOT, expected), tools()
    manifest = verify(bundle, source, toolchain)
    for name, (_, destination) in FAMILIES.items():
        shutil.copytree(bundle / 'payload' / name, output / destination)
        expected_files = {p[len(name) + 1:]: value for p, value in manifest['files'].items()
                          if p.startswith(name + '/')}
        if inventory(output / destination) != expected_files:
            raise ValueError(f'fixture copy changed: {name}')
    if source_identity(ROOT, expected) != source:
        raise ValueError('fixture consumer source changed during verification')
    evidence.parent.mkdir(parents=True, exist_ok=True)
    evidence.write_text(json.dumps({'version': 1, 'source': source,
        'manifest_sha256': digest(bundle / MANIFEST), 'build_seconds': manifest['build_seconds'],
        'restore_seconds': time.monotonic() - started,
        'scope': 'build reuse only; database lifecycle checks execute in this lane'}, indent=2) + '\n')


def summary(evidence):
    import csv
    with (evidence / 'phases.tsv').open() as stream:
        phases = list(csv.DictReader(stream, delimiter='\t'))
    lines = ['## Migration phase timings', '', '| Phase | Seconds | Exit |', '|---|---:|---:|']
    lines += [f"| {p['phase']} | {p['seconds']} | {p['exit_code']} |" for p in phases]
    reused = evidence / 'prebuilt-fixtures.json'
    if reused.exists():
        data = json.loads(reused.read_text())
        lines += ['', f"Verified shared fixture restore: {data['restore_seconds']:.3f}s.",
                  'Producer build seconds (paid once per matrix, not per PostgreSQL lane):',
                  '```json', json.dumps(data['build_seconds'], indent=2), '```']
    text = '\n'.join(lines) + '\n'
    print(text)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
            stream.write(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('build', 'restore', 'summary'))
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--expected-revision', default=os.environ.get('GITHUB_SHA'))
    args = parser.parse_args()
    required = {'build': ('bundle',), 'restore': ('bundle', 'output', 'evidence'), 'summary': ('evidence',)}
    for name in required[args.operation]:
        if getattr(args, name) is None:
            parser.error(f'--{name} is required for {args.operation}')
    if args.operation == 'summary':
        summary(args.evidence)
    elif args.operation == 'build':
        build(args.bundle.resolve(), args.expected_revision)
    else:
        restore(args.bundle.resolve(), args.output.resolve(), args.evidence.resolve(), args.expected_revision)


if __name__ == '__main__':
    main()

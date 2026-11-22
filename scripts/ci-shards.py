#!/usr/bin/env python3
"""Declare and verify the complete CI phase union across isolated runners."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SHARDS = ('compiler-integration', 'go-runtime', 'migration')
GO_PHASE = 'Go runtime + emitted-code gates'
# The migration shard may run as one job ('full') or as two parallel jobs whose
# contiguous phase lists join, in order, into the complete inventory.
MIGRATION_LANES = ('full', 'core', 'lifecycle')
MIGRATION_LANE_BOUNDARY = 'test_migration_row_indexes'
# Hosted jobs: (matrix job name, shard, migration lane).
JOBS = (('compiler-integration', 'compiler-integration', None), ('go-runtime', 'go-runtime', None),
        ('migration-core', 'migration', 'core'), ('migration-lifecycle', 'migration', 'lifecycle'))


class EvidenceError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def identity(root, expected):
    require(re.fullmatch(r'[0-9a-f]{40}', expected), 'expected revision must be a complete commit SHA')
    revision = git(root, 'rev-parse', 'HEAD')
    require(revision == expected, 'checked revision differs from expected revision')
    require(not git(root, 'status', '--porcelain', '--untracked-files=no'), 'tracked source is dirty')
    return {'revision': revision, 'tree': git(root, 'rev-parse', 'HEAD^{tree}'), 'tracked_clean': True}


def migration_lanes(config):
    phases = config['migration_phases']
    require(MIGRATION_LANE_BOUNDARY in phases, 'migration lane boundary is not a declared phase')
    boundary = phases.index(MIGRATION_LANE_BOUNDARY)
    return {'full': phases, 'core': phases[:boundary], 'lifecycle': phases[boundary:]}


def lane_of(shard, lane):
    if shard != 'migration':
        require(lane is None, 'only the migration shard runs in lanes')
        return None
    lane = lane or 'full'
    require(lane in MIGRATION_LANES, 'unknown migration lane')
    return lane


def migration_declarations(source):
    entries = []
    dynamic = []
    for match in re.finditer(r'^\s*(run_phase|runtime_test|compiler_test)\s+([^\s]+)', source, re.M):
        command, name = match.groups()
        if re.fullmatch(r'[a-zA-Z0-9_-]+', name):
            entries.append((match.start(), [name]))
        else:
            dynamic.append((command, name))
    require(sorted(dynamic) == sorted([('run_phase', '"$1"'), ('run_phase', '"$name"'),
                                       ('compiler_test', '"$suite"')]),
            'unrecognised dynamic migration phase declaration')
    loops = list(re.finditer(r'^\s*for suite in\s+(.*?)\s*;\s*do\s*compiler_test "\$suite"\s*done', source, re.M | re.S))
    require(len(loops) == 1, 'expected one closed compiler-suite inventory')
    names = loops[0].group(1).replace('\\\n', ' ').split()
    require(names and all(re.fullmatch(r'[a-zA-Z0-9_]+', name) for name in names),
            'compiler-suite inventory contains dynamic or invalid names')
    entries.append((loops[0].start(), names))
    return [name for _, group in sorted(entries) for name in group]


def inventory(root):
    path = root / 'scripts/ci-shards.json'
    config = json.loads(path.read_text())
    require(type(config.get('version')) is int and config['version'] == 1, 'unknown CI shard inventory version')
    phases = config.get('phases', [])
    require(len(phases) == 25, 'the authoritative parent phase inventory must contain all 25 phases')
    names = [item['name'] for item in phases]
    require(len(set(names)) == len(names), 'duplicate parent phase in inventory')
    declared = re.findall(r'^phase_begin "([^"]+)"\s*$', (root / 'ci.sh').read_text(), re.M)
    require(names == declared, 'ci.sh phase declarations differ from the complete shard inventory')
    require([item['name'] for item in phases if item['owners'] != ['compiler-integration']] == [GO_PHASE],
            'only the Go gate may be split into declared parts')
    require(next(item for item in phases if item['name'] == GO_PHASE)['owners'] == ['go-runtime', 'migration'],
            'Go gate requires both runtime and complete migration parts')
    require(all(set(item['owners']) <= set(SHARDS) for item in phases), 'unknown phase owner')
    workflow = (root / '.github/workflows/ci.yml').read_text()
    matrix = re.findall(r'^        job: \[([^\]]+)\]\s*$', workflow, re.M)
    require(len(matrix) == 1 and [name.strip(" \"'") for name in matrix[0].split(',')] == [job for job, _, _ in JOBS],
            'workflow matrix differs from the complete shard set')
    require(re.search(r'^      fail-fast: false\s*$', workflow, re.M), 'all shards must retain independent results')
    gate = re.search(r'^  gate:\n(.*?)(?=^  [a-zA-Z0-9_-]+:|\Z)', workflow, re.M | re.S)
    require(gate is not None, 'required authoritative aggregation job is missing')
    gate = gate.group(1)
    require(re.search(r'^    if: always\(\)\s*$', gate, re.M), 'authoritative aggregation must always run')
    require(re.search(r'^    needs: \[shards\]\s*$', gate, re.M), 'authoritative aggregation must depend on every shard')
    require('python3 scripts/ci-shards.py verify --expected-revision "$GITHUB_SHA"' in gate and
            'CI_UPSTREAM_RESULT: ${{ needs.shards.result }}' in gate,
            'authoritative aggregation must verify source-bound receipts and upstream outcome')
    migration = migration_declarations((root / 'scripts/run-migration-tests.sh').read_text())
    require(len(set(migration)) == len(migration), 'duplicate declared migration phase')
    require(migration == config.get('migration_phases'), 'complete migration declarations differ from inventory')
    return config


def owned(config, shard):
    require(shard in SHARDS, 'unknown CI shard')
    return [item['name'] for item in config['phases'] if shard in item['owners']]


def read_phases(path):
    with path.open(newline='') as stream:
        reader = csv.DictReader(stream, delimiter='\t')
        require(reader.fieldnames == ['phase', 'status', 'seconds'], 'invalid parent phase evidence header')
        rows = list(reader)
    for row in rows:
        require(set(row) == {'phase', 'status', 'seconds'}, 'malformed parent phase row')
        require(row['status'] in ('OK', 'FAIL', 'SKIP'), 'unknown parent phase status')
        require(re.fullmatch(r'[0-9]+', row['seconds']) is not None, 'invalid phase duration')
    return rows


def read_migration(path, config, lane='full'):
    with path.open(newline='') as stream:
        reader = csv.DictReader(stream, delimiter='\t')
        require(reader.fieldnames == ['phase', 'seconds', 'exit_code'], 'invalid migration phase evidence header')
        rows = list(reader)
    require([row.get('phase') for row in rows] == migration_lanes(config)[lane],
            'migration evidence is missing, duplicated, reordered, or unknown')
    for row in rows:
        require(set(row) == {'phase', 'seconds', 'exit_code'}, 'malformed migration phase row')
        require(re.fullmatch(r'[0-9]+', row['seconds']) is not None, 'invalid migration phase duration')
        require(row['exit_code'] == '0', 'migration phase did not pass')
    return rows


def read_parts(path, shard):
    expected = ['migration', 'go-runtime'] if shard == 'full' else [shard]
    require(shard in ('full', 'go-runtime', 'migration'), 'unknown Go gate part owner')
    with path.open(newline='') as stream:
        reader = csv.DictReader(stream, delimiter='\t')
        require(reader.fieldnames == ['part', 'status'], 'invalid Go gate parts header')
        rows = list(reader)
    require([row.get('part') for row in rows] == expected,
            'Go gate parts are missing, duplicated, reordered, or unowned')
    require(all(set(row) == {'part', 'status'} and row['status'] == 'OK' for row in rows),
            'a Go gate part failed or skipped')
    return rows


def start(root, shard, expected, output, lane=None):
    config = inventory(root)
    owned(config, shard)
    lane = lane_of(shard, lane)
    current = identity(root, expected)
    output.mkdir(parents=True, exist_ok=False)
    state = {'version': 1, 'shard': shard, 'source': current,
             'inventory_sha256': digest(root / 'scripts/ci-shards.json')}
    if lane is not None:
        state['lane'] = lane
    (output / 'source.json').write_text(json.dumps(state, indent=2) + '\n')
    (output / 'phases.tsv').write_text('phase\tstatus\tseconds\n')


def record(root, shard, expected, output, migration_path=None, lane=None):
    config = inventory(root)
    state = json.loads((output / 'source.json').read_text())
    errors = []
    try:
        require(type(state['version']) is int and state['version'] == 1 and state['shard'] == shard, 'shard start identity differs')
        require(state.get('lane') == lane_of(shard, lane), 'migration lane differs from its start identity')
        require(state['source'] == identity(root, expected), 'source changed during shard execution')
        require(state['inventory_sha256'] == digest(root / 'scripts/ci-shards.json'), 'phase inventory changed during execution')
        phases = read_phases(output / 'phases.tsv')
        require([row['phase'] for row in phases] == owned(config, shard),
                'shard evidence is missing, duplicated, reordered, or unowned')
        require(all(row['status'] == 'OK' for row in phases), 'a shard phase failed or skipped')
        if shard in ('go-runtime', 'migration'):
            read_parts(output / 'go-parts.tsv', shard)
        if shard == 'migration':
            require(migration_path is not None, 'complete migration evidence is required')
            read_migration(migration_path, config, state['lane'])
            shutil.copyfile(migration_path, output / 'migration-phases.tsv')
    except (EvidenceError, OSError, KeyError, ValueError) as error:
        errors.append(str(error))
    receipt = {**state, 'complete': not errors, 'errors': errors,
               'phases_sha256': digest(output / 'phases.tsv')}
    if shard in ('go-runtime', 'migration') and (output / 'go-parts.tsv').exists():
        receipt['go_parts_sha256'] = digest(output / 'go-parts.tsv')
    if shard == 'migration' and (output / 'migration-phases.tsv').exists():
        receipt['migration_phases_sha256'] = digest(output / 'migration-phases.tsv')
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    require(not errors, '; '.join(errors))


def verify(root, expected, evidence, upstream_result):
    config = inventory(root)
    current = identity(root, expected)
    require(upstream_result == 'success', 'one or more required upstream shards did not succeed')
    paths = sorted(evidence.rglob('receipt.json'))
    seen = set()
    covered = []
    migration_rows = {}
    migration_parents = []
    for path in paths:
        receipt = json.loads(path.read_text())
        shard = receipt.get('shard')
        require(shard in SHARDS, 'unknown shard receipt')
        require(shard != 'migration' or 'lane' in receipt, 'migration receipt does not name its lane')
        lane = lane_of(shard, receipt.get('lane'))
        key = (shard, lane)
        require(key not in seen, 'duplicate shard receipt')
        seen.add(key)
        require(type(receipt.get('version')) is int and receipt.get('version') == 1 and receipt.get('complete') is True and receipt.get('errors') == [],
                'shard receipt is incomplete or failed')
        require(receipt.get('source') == current and receipt['source'].get('tracked_clean') is True, 'shard source revision, tree or cleanliness differs')
        require(receipt.get('inventory_sha256') == digest(root / 'scripts/ci-shards.json'), 'shard phase inventory differs')
        phases_path = path.parent / 'phases.tsv'
        require(receipt.get('phases_sha256') == digest(phases_path), 'parent phase evidence hash differs')
        phases = read_phases(phases_path)
        require([row['phase'] for row in phases] == owned(config, shard), 'shard phase coverage differs')
        require(all(row['status'] == 'OK' for row in phases), 'a shard phase failed or skipped')
        if shard == 'migration':
            migration_parents.append([row['phase'] for row in phases])
        else:
            covered.extend((row['phase'], shard) for row in phases)
        if shard in ('go-runtime', 'migration'):
            parts_path = path.parent / 'go-parts.tsv'
            require(receipt.get('go_parts_sha256') == digest(parts_path), 'Go gate part evidence hash differs')
            read_parts(parts_path, shard)
        if shard == 'migration':
            migration_path = path.parent / 'migration-phases.tsv'
            require(receipt.get('migration_phases_sha256') == digest(migration_path), 'migration evidence hash differs')
            migration_rows[lane] = read_migration(migration_path, config, lane)
    require({shard for shard, _ in seen} == set(SHARDS), 'required shard is missing')
    require(sorted(migration_rows) in (['full'], ['core', 'lifecycle']),
            'migration evidence must be one complete run or both lanes')
    lanes = ['full'] if 'full' in migration_rows else ['core', 'lifecycle']
    joined = [row['phase'] for lane in lanes for row in migration_rows[lane]]
    require(joined == config['migration_phases'], 'migration lanes do not join into the complete inventory')
    require(len(migration_parents) == len(lanes) and all(p == migration_parents[0] for p in migration_parents),
            'migration lanes differ in their parent phases')
    covered.extend((name, 'migration') for name in migration_parents[0])
    require(sorted(covered) == sorted((item['name'], shard) for item in config['phases'] for shard in item['owners']),
            'authoritative phase/part union differs')
    return {'version': 1, 'source': current, 'parent_phases': len(config['phases']),
            'go_gate_parts': 2, 'migration_phases': len(config['migration_phases']),
            'migration_lanes': lanes, 'shards': sorted(SHARDS), 'status': 'success'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('inventory', 'list', 'start', 'record', 'verify', 'check-parts', 'check-migration'))
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--shard', choices=('full',) + SHARDS)
    parser.add_argument('--expected-revision', default=os.environ.get('GITHUB_SHA'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--migration-phases', type=Path)
    parser.add_argument('--upstream-result')
    parser.add_argument('--lane', choices=MIGRATION_LANES)
    args = parser.parse_args()
    try:
        config = inventory(args.root)
        if args.action == 'inventory':
            print(f"CI inventory: {len(config['phases'])} parent phases; two Go gate parts; {len(config['migration_phases'])} migration phases")
        elif args.action == 'list':
            for name in owned(config, args.shard) if args.shard else [item['name'] for item in config['phases']]:
                print(name)
        elif args.action == 'check-parts':
            require(args.shard and args.evidence, 'Go gate part owner and evidence are required')
            read_parts(args.evidence, args.shard)
        elif args.action == 'check-migration':
            require(args.evidence, 'complete migration evidence is required')
            read_migration(args.evidence, config, args.lane or 'full')
        elif args.action in ('start', 'record'):
            require(args.shard and args.expected_revision and args.output, 'shard, expected revision and output are required')
            if args.action == 'start':
                start(args.root, args.shard, args.expected_revision, args.output, args.lane)
            else:
                record(args.root, args.shard, args.expected_revision, args.output, args.migration_phases, args.lane)
        else:
            require(args.expected_revision and args.evidence and args.upstream_result,
                    'expected revision, evidence and upstream result are required')
            result = verify(args.root, args.expected_revision, args.evidence, args.upstream_result)
            if args.output:
                args.output.write_text(json.dumps(result, indent=2) + '\n')
            print(json.dumps(result, sort_keys=True))
    except (EvidenceError, OSError, KeyError, ValueError, subprocess.CalledProcessError) as error:
        print(f'CI evidence refused: {error}', file=sys.stderr)
        raise SystemExit(1)


if __name__ == '__main__':
    main()

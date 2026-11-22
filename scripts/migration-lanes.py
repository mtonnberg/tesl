#!/usr/bin/env python3
"""Plan and verify the exact source-bound union of parallel migration CI lanes."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import runpy
import sys

ROOT = Path(__file__).resolve().parents[1]
CI = runpy.run_path(str(ROOT / 'scripts/ci-shards.py'))
# The lanes, their order and prerequisites are declared once, in ci-shards.py.
LANES = tuple(name for name, _ in CI['MIGRATION_LANE_STARTS'])


def partitions(root=ROOT):
    return CI['migration_lanes'](CI['inventory'](root))


def plan(root, lane):
    """Runner prerequisites as GitHub step outputs (key=true|false lines)."""
    steps = CI['lane_plan'](CI['inventory'](root), lane)
    return ''.join(f'{key}={str(value).lower()}\n' for key, value in sorted(steps.items()))


def read_rows(path):
    with path.open() as stream:
        reader = csv.DictReader(stream, delimiter='\t')
        if reader.fieldnames != ['phase', 'seconds', 'exit_code']:
            raise ValueError('invalid migration phase receipt header')
        rows = list(reader)
    for row in rows:
        if set(row) != {'phase', 'seconds', 'exit_code'} or not row['seconds'].isdigit() or row['exit_code'] != '0':
            raise ValueError('migration lane contains failed or malformed phase evidence')
    return rows


def begin(root, lane, major, revision, directory):
    (directory / 'lane-receipt.json').unlink(missing_ok=True)
    source = CI['identity'](root, revision)
    state = {'version': 1, 'lane': lane, 'postgres': major, 'source': source,
             'expected_phases': partitions(root)[lane]}
    (directory / 'lane-source.json').write_text(json.dumps(state, sort_keys=True) + '\n')


def finish(root, lane, major, revision, directory, status):
    (directory / 'lane-receipt.json').unlink(missing_ok=True)
    state = json.loads((directory / 'lane-source.json').read_text())
    expected = {'version': 1, 'lane': lane, 'postgres': major,
                'source': CI['identity'](root, revision), 'expected_phases': partitions(root)[lane]}
    if state != expected or status != 0:
        raise ValueError('migration lane failed or changed its source identity')
    rows = read_rows(directory / 'phases.tsv')
    if [row['phase'] for row in rows] != expected['expected_phases']:
        raise ValueError('migration lane phase inventory is incomplete or reordered')
    state['phases_sha256'] = hashlib.sha256((directory / 'phases.tsv').read_bytes()).hexdigest()
    state['ok'] = True
    (directory / 'lane-receipt.json').write_text(json.dumps(state, sort_keys=True) + '\n')


def verify(root, directory, revision, major, upstream=None):
    # Every upstream lane job result must be present and successful: a matrix
    # job's result is 'success' only when all of its lanes succeeded.
    if not upstream or any(result != 'success' for result in upstream):
        raise ValueError('migration upstream lanes did not all succeed')
    source = CI['identity'](root, revision)
    expected = partitions(root)
    receipts = list(directory.rglob('lane-receipt.json'))
    if len(receipts) != len(LANES):
        raise ValueError('missing or duplicate migration lane receipts')
    combined, seen = {}, set()
    for path in receipts:
        receipt = json.loads(path.read_text())
        lane = receipt.get('lane')
        if lane not in LANES or lane in seen or type(receipt.get('version')) is not int or receipt['version'] != 1 or receipt.get('ok') is not True:
            raise ValueError('invalid or duplicate migration lane')
        if receipt.get('source') != source or receipt.get('postgres') != major or receipt.get('expected_phases') != expected[lane]:
            raise ValueError('migration lane source, major or inventory differs')
        phases = path.parent / 'phases.tsv'
        if hashlib.sha256(phases.read_bytes()).hexdigest() != receipt.get('phases_sha256'):
            raise ValueError('migration phase receipt bytes changed')
        rows = read_rows(phases)
        if [row['phase'] for row in rows] != expected[lane]:
            raise ValueError('migration lane omitted, duplicated or reordered a phase')
        combined[lane] = rows
        seen.add(lane)
    if seen != set(LANES):
        raise ValueError('migration lanes are missing')
    rows = [row for lane in LANES for row in combined[lane]]
    if [row['phase'] for row in rows] != expected['full']:
        raise ValueError('migration lane union is not the complete gate')
    return {'version': 1, 'source': source, 'postgres': major, 'ok': True, 'lanes': list(LANES),
            'phases': rows, 'phase_seconds': sum(int(row['seconds']) for row in rows)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('phases', 'plan', 'begin', 'finish', 'verify'))
    parser.add_argument('--lane', choices=('full', *LANES), default='full')
    parser.add_argument('--postgres', type=int, choices=range(14, 19))
    parser.add_argument('--revision', default=os.environ.get('GITHUB_SHA'))
    parser.add_argument('--directory', type=Path)
    parser.add_argument('--status', type=int, default=0)
    parser.add_argument('--upstream', action='append', default=[],
                        help='result of one upstream lane job (repeat for every lane job)')
    args = parser.parse_args()
    if args.operation == 'phases':
        print('\n'.join(partitions()[args.lane]))
        return
    if args.operation == 'plan':
        sys.stdout.write(plan(ROOT, args.lane))
        return
    if not args.revision or args.postgres is None or args.directory is None:
        parser.error('revision, postgres and directory are required for receipts')
    if args.operation == 'verify':
        print(json.dumps(verify(ROOT, args.directory, args.revision, args.postgres, args.upstream), indent=2))
    else:
        if args.lane == 'full':
            parser.error('lane receipts require a named lane')
        if args.operation == 'begin':
            begin(ROOT, args.lane, args.postgres, args.revision, args.directory)
        else:
            finish(ROOT, args.lane, args.postgres, args.revision, args.directory, args.status)

if __name__ == '__main__':
    main()

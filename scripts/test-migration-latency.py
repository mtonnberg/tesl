#!/usr/bin/env python3
"""Pure statistics/policy checks: no compiler, server, or database."""
import runpy
import json
from pathlib import Path
import tempfile
import unittest
import sys
from unittest import mock

bench = runpy.run_path(str(Path(__file__).with_name('compare-migration-latency.py')))


def samples(ns):
    return {'read': [ns] * bench['SAMPLES'], 'write': [ns] * bench['SAMPLES']}


class RegressionPolicy(unittest.TestCase):
    def test_in_checkout_evidence_is_excluded_from_snapshot(self):
        root = Path('/checkout')
        output = root / 'evidence'
        listed = b'app.tesl\0evidence/raw.jsonl\0evidence/candidate/app.tesl\0evidence-other/source.tesl\0'
        with mock.patch('subprocess.check_output', return_value=listed), \
             mock.patch.object(Path, 'is_file', return_value=True):
            self.assertEqual(list(bench['candidate_paths'](root, output)),
                             [Path('app.tesl'), Path('evidence-other/source.tesl')])

    def result(self, baseline, candidate):
        return bench['compare']([(samples(baseline), samples(candidate))] * 8)['read']['p50']

    def test_absolute_floor(self):
        self.assertTrue(self.result(100_000, 400_000)['passed'])
        self.assertFalse(self.result(100_000, 700_000)['passed'])

    def test_relative_threshold(self):
        self.assertTrue(self.result(10_000_000, 14_000_000)['passed'])
        self.assertFalse(self.result(10_000_000, 16_000_000)['passed'])

    def test_pairing_handles_shared_drift(self):
        pairs = [(samples(i * 10_000_000), samples(i * 10_000_000 + 500_000)) for i in range(1, 9)]
        result = bench['compare'](pairs)['write']['p95']
        self.assertEqual(result['upper99_delta_ns'], 500_000)

    def test_tail_regression_is_not_hidden_by_median(self):
        slow = samples(1_000_000)
        tail = bench['SAMPLES'] // 10
        slow['write'][-tail:] = [10_000_000] * tail
        result = bench['compare']([(samples(1_000_000), slow)] * 8)
        self.assertTrue(result['write']['p50']['passed'])
        self.assertFalse(result['write']['p95']['passed'])

    def test_bad_pairs_are_not_discarded(self):
        pairs = [(samples(1_000_000), samples(1_000_000))] * 6
        pairs += [(samples(1_000_000), samples(20_000_000))] * 2
        self.assertFalse(bench['compare'](pairs)['read']['p50']['passed'])

    def test_calibration_rejects_drift_in_either_direction(self):
        for a, b in ((1_000_000, 10_000_000), (10_000_000, 1_000_000)):
            result = bench['calibrated']([(samples(a), samples(b))] * 6)['read']['p50']
            self.assertGreater(result['noise_ns'], result['budget_ns'])

    def test_missing_pairs_fail(self):
        with self.assertRaises(ValueError):
            bench['compare']([])

    def test_missing_samples_fail(self):
        incomplete = samples(1_000_000)
        incomplete['read'].pop()
        with self.assertRaises(ValueError):
            bench['compare']([(samples(1_000_000), incomplete)] * 8)

    def test_missing_baseline_records_failure(self):
        with tempfile.TemporaryDirectory(prefix='latency-unit-', dir=Path(__file__).resolve().parents[1]) as directory:
            output = Path(directory) / 'evidence'
            with mock.patch('sys.argv', ['bench', '--baseline-ref', 'missing', '--output', str(output)]), \
                 mock.patch('shutil.which', return_value='/unused'), \
                 mock.patch.dict(bench['main'].__globals__, {'ROOT': Path(directory) / 'checkout',
                     'run': mock.Mock(side_effect=RuntimeError('unknown baseline'))}), \
                 mock.patch('signal.signal'):
                with self.assertRaisesRegex(RuntimeError, 'unknown baseline'):
                    bench['main']()
            result = json.loads((output / 'result.json').read_text())
            self.assertEqual(result['status'], 'failed')
            self.assertEqual(result['baseline_ref'], 'missing')


def audit_evidence(directory):
    """Replay real observations and test deliberately slowed copies, never a live injection."""
    policy = json.loads((directory / 'result.json').read_text())['policy']
    groups = {}
    for line in (directory / 'raw.jsonl').read_text().splitlines():
        row = json.loads(line)
        if row['warmup']:
            continue
        key = (row['phase'], row['pair'], row['position'], row['revision'])
        side = groups.setdefault(key, {'read': [], 'write': []})
        for op in side:
            side[op].append(row[op + '_ns'])
    calibration = [(groups['calibration', i, 0, 'baseline'], groups['calibration', i, 1, 'baseline'])
                   for i in range(policy['calibration_pairs'])]
    pairs = [(groups['comparison', i, i % 2, 'baseline'], groups['comparison', i, 1 - i % 2, 'candidate'])
             for i in range(policy['pairs'])]
    # Add 3ms to every measured candidate request. Preserve actual pair noise.
    slow = [(a, {op: [ns + 3_000_000 for ns in values] for op, values in b.items()}) for a, b in pairs]
    rejected = bench['compare'](slow, policy['samples'])
    assert all(not metric['passed'] for op in rejected.values() for metric in op.values()), rejected
    print(json.dumps({'calibration': bench['calibrated'](calibration, policy['samples']),
                      'comparison': bench['compare'](pairs, policy['samples']), 'deliberate_3ms_slowdown': rejected,
                      'run_quantiles_ns': {str(key): {op: {q: bench['percentile'](values, p)
                          for q, p in (('p50', .5), ('p95', .95))} for op, values in side.items()}
                          for key, side in groups.items()}}, indent=2))


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--evidence':
        audit_evidence(Path(sys.argv[2]))
    else:
        unittest.main()

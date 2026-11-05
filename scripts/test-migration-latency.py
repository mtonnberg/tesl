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
    def test_available_baseline_needs_no_network(self):
        run = mock.Mock(return_value=bench['BASELINE'])
        with mock.patch.dict(bench['prepare_baseline'].__globals__, {'run': run}):
            self.assertEqual(bench['prepare_baseline'](bench['BASELINE'], fetch=True), bench['BASELINE'])
        self.assertEqual(run.call_count, 1)

    def test_squashed_baseline_fetches_exact_commit(self):
        ref = bench['BASELINE']
        root = Path('/checkout')
        run = mock.Mock(side_effect=[RuntimeError('missing'), '', ref])
        with mock.patch.dict(bench['prepare_baseline'].__globals__, {'run': run}):
            self.assertEqual(bench['prepare_baseline'](ref, fetch=True, root=root), ref)
        self.assertEqual(run.call_args_list[1], mock.call(
            ['git', 'fetch', '--no-tags', '--no-write-fetch-head', 'origin', ref], cwd=root, timeout=120))
        self.assertEqual(run.call_args_list[0], run.call_args_list[2])

    def test_preflight_missing_baseline_fails_without_fetching(self):
        run = mock.Mock(side_effect=RuntimeError('missing'))
        with mock.patch.dict(bench['prepare_baseline'].__globals__, {'run': run}):
            with self.assertRaisesRegex(RuntimeError, 'Full main history does not include squashed'):
                bench['prepare_baseline'](bench['BASELINE'])
        self.assertEqual(run.call_count, 1)

    def test_fetch_refuses_moving_names_and_wrong_objects(self):
        for ref in ('main', '9852f26', '--upload-pack=other'):
            run = mock.Mock(side_effect=RuntimeError('missing'))
            with mock.patch.dict(bench['prepare_baseline'].__globals__, {'run': run}):
                with self.assertRaisesRegex(RuntimeError, 'full commit SHA'):
                    bench['prepare_baseline'](ref, fetch=True)
            self.assertEqual(run.call_count, 1)
        run = mock.Mock(side_effect=[RuntimeError('missing'), '', '0' * 40])
        with mock.patch.dict(bench['prepare_baseline'].__globals__, {'run': run}):
            with self.assertRaisesRegex(RuntimeError, 'differs'):
                bench['prepare_baseline'](bench['BASELINE'], fetch=True)

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

    def test_larger_fixed_calibration_still_rejects_noisy_write_tails(self):
        slow = samples(1_000_000)
        slow['write'][-bench['SAMPLES'] // 10:] = [3_000_000] * (bench['SAMPLES'] // 10)
        pairs = [(samples(1_000_000), slow)] * bench['CALIBRATION_PAIRS']
        result = bench['calibrated'](pairs)
        self.assertLessEqual(result['read']['p95']['noise_ns'], result['read']['p95']['budget_ns'])
        self.assertGreater(result['write']['p95']['noise_ns'], result['write']['p95']['budget_ns'])

    def test_host_qualification_retains_failed_trials_without_candidate_samples(self):
        evidence, calls = {}, []
        def sample(label, phase, pair, position):
            calls.append((label, phase, pair, position))
            return samples(4_000_000 if pair < bench['CALIBRATION_PAIRS'] and position == 1 else 1_000_000)
        pause = mock.Mock()
        bench['qualify_host'](sample, evidence, pause)
        self.assertEqual(evidence['calibration_selected_attempt'], 1)
        self.assertEqual([a['qualified'] for a in evidence['calibration_attempts']], [False, True])
        self.assertEqual(len(calls), 4 * bench['CALIBRATION_PAIRS'])
        self.assertEqual(len(set(calls)), len(calls))
        self.assertTrue(all(label == 'baseline' and phase == 'calibration' for label, phase, _, _ in calls))
        pause.assert_called_once_with(bench['CALIBRATION_PAUSE_SECONDS'])

    def test_host_qualification_is_bounded_and_does_not_retry_correctness_errors(self):
        evidence = {}
        sample = mock.Mock(side_effect=lambda label, phase, pair, position: samples(1_000_000 if position == 0 else 4_000_000))
        pause = mock.Mock()
        with self.assertRaisesRegex(RuntimeError, 'no regression verdict'):
            bench['qualify_host'](sample, evidence, pause)
        self.assertEqual(sample.call_count, 2 * bench['CALIBRATION_PAIRS'] * bench['CALIBRATION_ATTEMPTS'])
        self.assertEqual(len(evidence['calibration_attempts']), bench['CALIBRATION_ATTEMPTS'])
        self.assertNotIn('calibration_selected_attempt', evidence)
        self.assertEqual(evidence['failure_kind'], 'calibration-noise')
        broken = mock.Mock(side_effect=RuntimeError('incorrect stored value'))
        with self.assertRaisesRegex(RuntimeError, 'incorrect stored value'):
            bench['qualify_host'](broken, {}, mock.Mock())
        broken.assert_called_once()

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
    evidence = json.loads((directory / 'result.json').read_text())
    policy = evidence['policy']
    groups = {}
    for line in (directory / 'raw.jsonl').read_text().splitlines():
        row = json.loads(line)
        if row['warmup']:
            continue
        key = (row['phase'], row['pair'], row['position'], row['revision'])
        side = groups.setdefault(key, {'read': [], 'write': []})
        for op in side:
            side[op].append(row[op + '_ns'])
    attempts = evidence.get('calibration_attempts', [{'first_pair': 0}])
    calibrations = []
    for attempt in attempts:
        first = attempt['first_pair']
        calibration = [(groups['calibration', i, 0, 'baseline'], groups['calibration', i, 1, 'baseline'])
                       for i in range(first, first + policy['calibration_pairs'])]
        calibrations.append(bench['calibrated'](calibration, policy['samples']))
    if not any(key[0] == 'comparison' for key in groups):
        print(json.dumps({'calibration_attempts': calibrations, 'comparison': None,
                          'regression_verdict': 'not available'}, indent=2))
        return
    selected = evidence.get('calibration_selected_attempt', 0)
    pairs = [(groups['comparison', i, i % 2, 'baseline'], groups['comparison', i, 1 - i % 2, 'candidate'])
             for i in range(policy['pairs'])]
    # Add 3ms to every measured candidate request. Preserve actual pair noise.
    slow = [(a, {op: [ns + 3_000_000 for ns in values] for op, values in b.items()}) for a, b in pairs]
    rejected = bench['compare'](slow, policy['samples'])
    assert all(not metric['passed'] for op in rejected.values() for metric in op.values()), rejected
    print(json.dumps({'calibration': calibrations[selected], 'calibration_attempts': calibrations,
                      'comparison': bench['compare'](pairs, policy['samples']), 'deliberate_3ms_slowdown': rejected,
                      'run_quantiles_ns': {str(key): {op: {q: bench['percentile'](values, p)
                          for q, p in (('p50', .5), ('p95', .95))} for op, values in side.items()}
                          for key, side in groups.items()}}, indent=2))


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--evidence':
        audit_evidence(Path(sys.argv[2]))
    else:
        unittest.main()

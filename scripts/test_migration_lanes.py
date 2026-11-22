"""Every original migration phase must survive the parallel hosted lane split."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('lanes', Path(__file__).with_name('migration-lanes.py'))
lanes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lanes)
SUCCESS = ['success', 'success']


class LaneReceipts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = {'revision': 'a' * 40, 'tree': 'b' * 40, 'tracked_clean': True}
        patch = mock.patch.dict(lanes.CI, identity=lambda root, expected: self.source)
        patch.start()
        self.addCleanup(patch.stop)

    def receipt(self, lane, directory=None):
        directory = self.root / (directory or lane)
        directory.mkdir()
        lanes.begin(lanes.ROOT, lane, 18, 'a' * 40, directory)
        (directory / 'phases.tsv').write_text('phase\tseconds\texit_code\n' + ''.join(
            f'{name}\t1\t0\n' for name in lanes.partitions()[lane]))
        lanes.finish(lanes.ROOT, lane, 18, 'a' * 40, directory, 0)

    def receipts(self, selected=None):
        for lane in lanes.LANES if selected is None else selected:
            self.receipt(lane)

    def verify(self, upstream=SUCCESS):
        return lanes.verify(lanes.ROOT, self.root, 'a' * 40, 18, upstream)

    def test_partition_is_exact_contiguous_and_shared_with_ci(self):
        parts = lanes.partitions()
        self.assertEqual(lanes.LANES, tuple(lane for lane, _ in lanes.CI['MIGRATION_LANE_STARTS']))
        self.assertGreaterEqual(len(lanes.LANES), 4)
        self.assertEqual([name for lane in lanes.LANES for name in parts[lane]], parts['full'])
        self.assertEqual(len(set(parts['full'])), len(parts['full']))
        self.assertEqual(parts['kernel'], ['compiler-build', 'kernel'])
        self.assertTrue(all(parts[lane] for lane in lanes.LANES))
        self.assertEqual(parts[lanes.LANES[-1]][-1], 'latency-regression')
        # review05/review11 read the row and queue release builds of their runner.
        self.assertTrue(any({'row-releases', 'queue-releases', 'review05', 'review11'} <= set(parts[lane])
                            for lane in lanes.LANES))

    def test_plan_reports_each_lanes_prerequisites(self):
        for lane in lanes.LANES:
            with self.subTest(lane=lane):
                lines = lanes.plan(lanes.ROOT, lane).splitlines()
                values = dict(line.split('=') for line in lines)
                self.assertEqual(sorted(values), ['bootstrap', 'latency', 'prebuilt'])
                self.assertEqual(values['bootstrap'], 'false' if lane == 'kernel' else 'true')
                self.assertEqual(values['latency'], 'true' if lane == lanes.LANES[-1] else 'false')
                self.assertIn(values['prebuilt'], ('true', 'false'))
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('migration-lanes.py')), 'plan',
                                 '--lane', 'full'], capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, 'bootstrap=false\nlatency=true\nprebuilt=true\n')

    def test_complete_union(self):
        self.receipts()
        result = self.verify()
        self.assertTrue(result['ok'])
        self.assertEqual(result['lanes'], list(lanes.LANES))
        self.assertEqual(len(result['phases']), len(lanes.partitions()['full']))

    def test_missing_duplicate_wrong_major_and_changed_source_refuse(self):
        self.receipts()
        receipt = self.root / 'kernel/lane-receipt.json'
        original = receipt.read_text()
        for change in ({'postgres': 14}, {'lane': 'runtime'}, {'lane': 'core'}, {'source': {}}, {'ok': False}):
            value = json.loads(original)
            value.update(change)
            receipt.write_text(json.dumps(value))
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.verify()
        receipt.unlink()
        with self.assertRaises(ValueError):
            self.verify()

    def test_every_single_missing_lane_refuses(self):
        for missing in lanes.LANES:
            with self.subTest(missing=missing):
                shutil.rmtree(self.root)
                self.root.mkdir()
                self.receipts([lane for lane in lanes.LANES if lane != missing])
                with self.assertRaisesRegex(ValueError, 'missing or duplicate'):
                    self.verify()

    def test_duplicate_lane_in_place_of_a_missing_one_refuses(self):
        self.receipts(lanes.LANES[:-1])
        self.receipt(lanes.LANES[0], 'again')
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            self.verify()

    def test_extra_duplicate_lane_refuses(self):
        self.receipts()
        self.receipt(lanes.LANES[1], 'again')
        with self.assertRaisesRegex(ValueError, 'missing or duplicate'):
            self.verify()

    def test_truncated_failed_and_reordered_phases_cannot_publish(self):
        self.receipts()
        directory = self.root / 'runtime'
        receipt = directory / 'lane-receipt.json'
        receipt.unlink()
        phases = directory / 'phases.tsv'
        original = phases.read_text().splitlines()
        for lines in (original[:-1], [original[0], *reversed(original[1:])],
                      [original[0], original[1].removesuffix('\t0') + '\t1', *original[2:]]):
            phases.write_text('\n'.join(lines) + '\n')
            with self.assertRaises(ValueError):
                lanes.finish(lanes.ROOT, 'runtime', 18, 'a' * 40, directory, 0)
            self.assertFalse(receipt.exists())
        phases.write_text('\n'.join(original) + '\n')
        with self.assertRaises(ValueError):
            lanes.finish(lanes.ROOT, 'runtime', 18, 'a' * 40, directory, 1)

    def test_lane_publishing_another_lanes_phases_refuses(self):
        directory = self.root / 'swapped'
        directory.mkdir()
        lanes.begin(lanes.ROOT, 'runtime', 18, 'a' * 40, directory)
        (directory / 'phases.tsv').write_text('phase\tseconds\texit_code\n' + ''.join(
            f'{name}\t1\t0\n' for name in lanes.partitions()['schema']))
        with self.assertRaises(ValueError):
            lanes.finish(lanes.ROOT, 'runtime', 18, 'a' * 40, directory, 0)

    def test_changed_evidence_after_publication_refuses(self):
        self.receipts()
        with (self.root / 'kernel/phases.tsv').open('a') as stream:
            stream.write('invented\t1\t0\n')
        with self.assertRaisesRegex(ValueError, 'bytes changed'):
            self.verify()

    def test_failed_repeat_cannot_retain_a_previous_success(self):
        self.receipts()
        directory = self.root / 'kernel'
        with self.assertRaises(ValueError):
            lanes.finish(lanes.ROOT, 'kernel', 18, 'a' * 40, directory, 1)
        self.assertFalse((directory / 'lane-receipt.json').exists())

    def test_failed_or_absent_upstream_cannot_borrow_prior_successful_receipts(self):
        self.receipts()
        for upstream in (['success', 'failure'], ['cancelled', 'success'], ['success', 'skipped'],
                         ['success', ''], [], None):
            with self.subTest(upstream=upstream), self.assertRaisesRegex(ValueError, 'upstream'):
                self.verify(upstream)


if __name__ == '__main__':
    unittest.main()

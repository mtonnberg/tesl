"""Every original migration phase must survive the two-lane hosted split."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('lanes', Path(__file__).with_name('migration-lanes.py'))
lanes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lanes)


class LaneReceipts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = {'revision': 'a' * 40, 'tree': 'b' * 40, 'tracked_clean': True}
        patch = mock.patch.dict(lanes.CI, identity=lambda root, expected: self.source)
        patch.start()
        self.addCleanup(patch.stop)

    def receipts(self):
        for lane in lanes.LANES:
            directory = self.root / lane
            directory.mkdir()
            lanes.begin(lanes.ROOT, lane, 18, 'a' * 40, directory)
            (directory / 'phases.tsv').write_text('phase\tseconds\texit_code\n' + ''.join(
                f'{name}\t1\t0\n' for name in lanes.partitions()[lane]))
            lanes.finish(lanes.ROOT, lane, 18, 'a' * 40, directory, 0)

    def test_partition_is_exact_and_expensive_shared_fixtures_are_late(self):
        parts = lanes.partitions()
        self.assertEqual(parts['core'] + parts['lifecycle'], parts['full'])
        self.assertEqual(len(set(parts['full'])), len(parts['full']))
        self.assertIn('kernel', parts['core'])
        self.assertIn('test_migration_row_indexes', parts['lifecycle'])
        self.assertIn('twenty-releases', parts['lifecycle'])
        self.assertEqual(parts['lifecycle'][-1], 'latency-regression')

    def test_complete_union(self):
        self.receipts()
        result = lanes.verify(lanes.ROOT, self.root, 'a' * 40, 18)
        self.assertTrue(result['ok'])
        self.assertEqual(len(result['phases']), len(lanes.partitions()['full']))

    def test_missing_duplicate_wrong_major_and_changed_source_refuse(self):
        self.receipts()
        receipt = self.root / 'core/lane-receipt.json'
        original = receipt.read_text()
        for change in ({'postgres': 14}, {'lane': 'lifecycle'}, {'source': {}}, {'ok': False}):
            value = json.loads(original)
            value.update(change)
            receipt.write_text(json.dumps(value))
            with self.assertRaises(ValueError):
                lanes.verify(lanes.ROOT, self.root, 'a' * 40, 18)
        receipt.unlink()
        with self.assertRaises(ValueError):
            lanes.verify(lanes.ROOT, self.root, 'a' * 40, 18)

    def test_truncated_failed_and_reordered_phases_cannot_publish(self):
        self.receipts()
        directory = self.root / 'core'
        receipt = directory / 'lane-receipt.json'
        receipt.unlink()
        phases = directory / 'phases.tsv'
        original = phases.read_text().splitlines()
        for lines in (original[:-1], [original[0], *reversed(original[1:])],
                      [original[0], original[1].removesuffix('\t0') + '\t1', *original[2:]]):
            phases.write_text('\n'.join(lines) + '\n')
            with self.assertRaises(ValueError):
                lanes.finish(lanes.ROOT, 'core', 18, 'a' * 40, directory, 0)
            self.assertFalse(receipt.exists())
        phases.write_text('\n'.join(original) + '\n')
        with self.assertRaises(ValueError):
            lanes.finish(lanes.ROOT, 'core', 18, 'a' * 40, directory, 1)

    def test_changed_evidence_after_publication_refuses(self):
        self.receipts()
        with (self.root / 'core/phases.tsv').open('a') as stream:
            stream.write('invented\t1\t0\n')
        with self.assertRaisesRegex(ValueError, 'bytes changed'):
            lanes.verify(lanes.ROOT, self.root, 'a' * 40, 18)

    def test_failed_repeat_cannot_retain_a_previous_success(self):
        self.receipts()
        directory = self.root / 'core'
        with self.assertRaises(ValueError):
            lanes.finish(lanes.ROOT, 'core', 18, 'a' * 40, directory, 1)
        self.assertFalse((directory / 'lane-receipt.json').exists())

    def test_failed_upstream_cannot_borrow_prior_successful_receipts(self):
        self.receipts()
        for upstream in [('success', 'failure'), ('cancelled', 'success'), ('success', 'skipped')]:
            with self.assertRaisesRegex(ValueError, 'upstream'):
                lanes.verify(lanes.ROOT, self.root, 'a' * 40, 18, upstream)


if __name__ == '__main__':
    unittest.main()

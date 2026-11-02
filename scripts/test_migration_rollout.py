#!/usr/bin/env python3
"""Acceptance arithmetic and resource/progress evidence for the rollout driver."""
import importlib.util
from pathlib import Path
import sys
import unittest
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from migration_rollout_workload import compare_budget, resource_estimate, summarize
spec = importlib.util.spec_from_file_location('measure_rollout', ROOT / 'measure-migration-rollout.py')
rollout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rollout)
class RolloutEvidenceTests(unittest.TestCase):
    def metric(self, nanoseconds):
        return dict(samples=1000, errors=0, p99Ns=nanoseconds)
    def test_exact_budgets(self):
        for budget, boundary in ((.01, 101), (.05, 105)):
            with self.subTest(budget=budget):
                self.assertTrue(compare_budget(self.metric(100), self.metric(boundary), budget)['observedPassed'])
                self.assertFalse(compare_budget(self.metric(100), self.metric(boundary + 1), budget)['observedPassed'])
    def test_insufficient_or_failed_evidence(self):
        for candidate in ({'samples':999,'errors':0,'p99Ns':1}, {'samples':1000,'errors':1,'p99Ns':1}, {'samples':1000,'errors':0,'p99Ns':None}):
            self.assertFalse(compare_budget(self.metric(100), candidate, .01)['observedPassed'])
    def test_errors_remain_visible(self):
        self.assertEqual(summarize([{'ok':False,'elapsedNs':3}]), {'samples':1,'errors':1,'p50Ns':None,'p95Ns':None,'p99Ns':None})
    def test_resource_reserve(self):
        self.assertFalse(resource_estimate(1000,100,800000+(2<<30))['allowed'])
        self.assertTrue(resource_estimate(1000,100,800001+(2<<30))['allowed'])
        self.assertFalse(resource_estimate(100_000_000,256,23_000_000_000)['allowed'])
    def test_progress_excludes_startup(self):
        self.assertEqual(rollout.backfill_rate([])['status'], 'insufficient-evidence')
        rate=rollout.backfill_rate([{'at':1,'rowsDone':0},{'at':11,'rowsDone':100},{'at':13,'rowsDone':300}])
        self.assertEqual((rate['rows'],rate['seconds'],rate['rowsPerSecond']), (200,2,100))
if __name__ == '__main__':
    unittest.main()

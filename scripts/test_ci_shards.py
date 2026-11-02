#!/usr/bin/env python3
"""Fail-closed tests for the authoritative CI shard evidence contract."""
import copy
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ci_shards', ROOT / 'scripts/ci-shards.py')
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class ShardEvidence(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix='tesl-ci-contract-')
        cls.base = Path(cls.scratch.name) / 'base'
        cls.base.mkdir()
        for name in ('ci.sh', 'scripts/ci-shards.py', 'scripts/ci-shards.json',
                     'scripts/run-migration-tests.sh', '.github/workflows/ci.yml'):
            destination = cls.base / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, destination)
        subprocess.run(['git', 'init', '-q', cls.base], check=True)
        subprocess.run(['git', '-C', str(cls.base), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(cls.base), '-c', 'user.name=CI fixture',
                        '-c', 'user.email=ci-fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
        cls.revision = ci.git(cls.base, 'rev-parse', 'HEAD')
        cls.config = ci.inventory(cls.base)

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='tesl-ci-evidence-')
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name) / 'repo'
        shutil.copytree(self.base, self.root)
        self.evidence = Path(self.work.name) / 'evidence'
        for shard in ci.SHARDS:
            output = self.evidence / shard
            ci.start(self.root, shard, self.revision, output)
            self.write_parent(shard, [{'phase': name, 'status': 'OK', 'seconds': '1'}
                                      for name in ci.owned(self.config, shard)])
            if shard in ('go-runtime', 'migration'):
                (output / 'go-parts.tsv').write_text(f'part\tstatus\n{shard}\tOK\n')
            migration = None
            if shard == 'migration':
                migration = Path(self.work.name) / 'migration.tsv'
                migration.write_text('phase\tseconds\texit_code\n' + ''.join(
                    f'{name}\t1\t0\n' for name in self.config['migration_phases']))
            ci.record(self.root, shard, self.revision, output, migration)

    def receipt(self, shard):
        return self.evidence / shard / 'receipt.json'

    def change_receipt(self, shard, transform):
        path = self.receipt(shard)
        value = json.loads(path.read_text())
        transform(value)
        path.write_text(json.dumps(value))

    def write_parent(self, shard, rows):
        path = self.evidence / shard / 'phases.tsv'
        path.write_text('phase\tstatus\tseconds\n' + ''.join(
            f"{row['phase']}\t{row['status']}\t{row['seconds']}\n" for row in rows))
        if self.receipt(shard).exists():
            self.change_receipt(shard, lambda value: value.update(phases_sha256=ci.digest(path)))

    def change_migration(self, transform):
        path = self.evidence / 'migration/migration-phases.tsv'
        lines = path.read_text().splitlines()
        transform(lines)
        path.write_text('\n'.join(lines) + '\n')
        self.change_receipt('migration', lambda value: value.update(migration_phases_sha256=ci.digest(path)))

    def verify(self, result='success'):
        return ci.verify(self.root, self.revision, self.evidence, result)

    def test_exact_union_passes(self):
        result = self.verify()
        self.assertEqual(result['parent_phases'], 24)
        self.assertEqual(result['go_gate_parts'], 2)
        self.assertEqual(result['migration_phases'], len(self.config['migration_phases']))
        self.assertEqual(result['status'], 'success')

    def test_missing_receipt_refuses(self):
        self.receipt('migration').unlink()
        with self.assertRaises(ci.EvidenceError):
            self.verify()

    def test_duplicate_receipt_refuses(self):
        shutil.copytree(self.evidence / 'go-runtime', self.evidence / 'duplicate')
        with self.assertRaises(ci.EvidenceError):
            self.verify()

    def test_wrong_or_duplicate_shard_refuses(self):
        for name in ('compiler-integration', 'unknown'):
            with self.subTest(shard=name):
                self.change_receipt('go-runtime', lambda value: value.update(shard=name))
                with self.assertRaises(ci.EvidenceError):
                    self.verify()

    def test_wrong_revision_tree_or_dirty_claim_refuses(self):
        original = json.loads(self.receipt('go-runtime').read_text())
        for field, value in (('revision', 'a' * 40), ('tree', 'b' * 40), ('tracked_clean', False)):
            with self.subTest(field=field):
                changed = copy.deepcopy(original)
                changed['source'][field] = value
                self.receipt('go-runtime').write_text(json.dumps(changed))
                with self.assertRaises(ci.EvidenceError):
                    self.verify()

    def test_tracked_source_change_refuses(self):
        with (self.root / 'ci.sh').open('a') as stream:
            stream.write('\n# changed after source capture\n')
        with self.assertRaisesRegex(ci.EvidenceError, 'dirty'):
            self.verify()

    def test_failed_skipped_or_incomplete_receipt_refuses(self):
        for field, value in (('complete', False), ('errors', ['failed'])):
            with self.subTest(field=field):
                self.change_receipt('migration', lambda receipt: receipt.update({field: value}))
                with self.assertRaises(ci.EvidenceError):
                    self.verify()

    def test_failed_or_skipped_parent_phase_refuses(self):
        for status in ('FAIL', 'SKIP'):
            with self.subTest(status=status):
                rows = ci.read_phases(self.evidence / 'go-runtime/phases.tsv')
                rows[0]['status'] = status
                self.write_parent('go-runtime', rows)
                with self.assertRaises(ci.EvidenceError):
                    self.verify()

    def test_missing_duplicate_or_unowned_parent_phase_refuses(self):
        original = ci.read_phases(self.evidence / 'compiler-integration/phases.tsv')
        for rows in (original[:-1], original + [original[0]],
                     original + [{'phase': ci.GO_PHASE, 'status': 'OK', 'seconds': '1'}]):
            with self.subTest(size=len(rows)):
                self.write_parent('compiler-integration', rows)
                with self.assertRaises(ci.EvidenceError):
                    self.verify()

    def test_phase_file_tampering_refuses(self):
        with (self.evidence / 'go-runtime/phases.tsv').open('a') as stream:
            stream.write('forged\tOK\t1\n')
        with self.assertRaisesRegex(ci.EvidenceError, 'hash'):
            self.verify()

    def test_registry_identity_mismatch_refuses(self):
        self.change_receipt('migration', lambda value: value.update(inventory_sha256='c' * 64))
        with self.assertRaises(ci.EvidenceError):
            self.verify()

    def test_truncated_migration_evidence_refuses(self):
        self.change_migration(lambda rows: rows.pop())
        with self.assertRaisesRegex(ci.EvidenceError, 'migration evidence'):
            self.verify()

    def test_duplicated_migration_phase_refuses(self):
        self.change_migration(lambda rows: rows.append(rows[1]))
        with self.assertRaises(ci.EvidenceError):
            self.verify()

    def test_failed_migration_phase_refuses(self):
        self.change_migration(lambda rows: rows.__setitem__(1, rows[1][:-1] + '1'))
        with self.assertRaisesRegex(ci.EvidenceError, 'did not pass'):
            self.verify()

    def test_missing_migration_part_cannot_hide_in_successful_runtime(self):
        shutil.rmtree(self.evidence / 'migration')
        with self.assertRaises(ci.EvidenceError):
            self.verify()

    def test_rolling_workload_smoke_evidence_is_required(self):
        self.assertIn('rolling-workload-smoke', self.config['migration_phases'])
        self.change_migration(lambda rows: rows.remove(next(
            row for row in rows if row.startswith('rolling-workload-smoke\t'))))
        with self.assertRaisesRegex(ci.EvidenceError, 'migration evidence'):
            self.verify()

    def test_missing_failed_skipped_or_duplicate_part_refuses(self):
        path = self.evidence / 'go-runtime/go-parts.tsv'
        for content in ('part\tstatus\n', 'part\tstatus\ngo-runtime\tFAIL\n',
                        'part\tstatus\ngo-runtime\tSKIP\n',
                        'part\tstatus\ngo-runtime\tOK\ngo-runtime\tOK\n',
                        'part\tstatus\nmigration\tOK\n'):
            with self.subTest(content=content):
                path.write_text(content)
                self.change_receipt('go-runtime', lambda value: value.update(go_parts_sha256=ci.digest(path)))
                with self.assertRaises(ci.EvidenceError):
                    self.verify()

    def test_full_serial_requires_both_successful_parts_in_order(self):
        path = Path(self.work.name) / 'full-parts.tsv'
        path.write_text('part\tstatus\nmigration\tOK\ngo-runtime\tOK\n')
        self.assertEqual(len(ci.read_parts(path, 'full')), 2)
        for parts in ([], ['go-runtime'], ['migration'], ['go-runtime', 'migration'],
                      ['migration', 'go-runtime', 'go-runtime']):
            with self.subTest(parts=parts):
                path.write_text('part\tstatus\n' + ''.join(f'{part}\tOK\n' for part in parts))
                with self.assertRaises(ci.EvidenceError):
                    ci.read_parts(path, 'full')

    def test_upstream_failure_cancel_or_skip_refuses(self):
        for result in ('failure', 'cancelled', 'skipped', ''):
            with self.subTest(result=result), self.assertRaises(ci.EvidenceError):
                self.verify(result)

    def test_incomplete_execution_writes_failed_receipt(self):
        output = Path(self.work.name) / 'partial'
        ci.start(self.root, 'go-runtime', self.revision, output)
        with self.assertRaises(ci.EvidenceError):
            ci.record(self.root, 'go-runtime', self.revision, output)
        receipt = json.loads((output / 'receipt.json').read_text())
        self.assertIs(receipt['complete'], False)
        self.assertTrue(receipt['errors'])

    def test_unknown_new_parent_phase_refuses(self):
        with (self.root / 'ci.sh').open('a') as stream:
            stream.write('\nphase_begin "Unassigned new check"\n')
        with self.assertRaisesRegex(ci.EvidenceError, 'phase declarations'):
            ci.inventory(self.root)

    def test_unknown_migration_phase_refuses(self):
        with (self.root / 'scripts/run-migration-tests.sh').open('a') as stream:
            stream.write('\nrun_phase unknown-new-check 30 true\n')
        with self.assertRaisesRegex(ci.EvidenceError, 'migration declarations'):
            ci.inventory(self.root)

    def test_incomplete_workflow_matrix_refuses(self):
        path = self.root / '.github/workflows/ci.yml'
        path.write_text(path.read_text().replace('[compiler-integration, go-runtime, migration]',
                                                 '[compiler-integration, go-runtime]'))
        with self.assertRaisesRegex(ci.EvidenceError, 'workflow matrix'):
            ci.inventory(self.root)

    def test_gate_without_always_refuses(self):
        path = self.root / '.github/workflows/ci.yml'
        path.write_text(path.read_text().replace('    if: always()', '    if: success()'))
        with self.assertRaisesRegex(ci.EvidenceError, 'always'):
            ci.inventory(self.root)

    def test_gate_without_all_upstream_shards_refuses(self):
        path = self.root / '.github/workflows/ci.yml'
        path.write_text(path.read_text().replace('    needs: [shards]', '    needs: []'))
        with self.assertRaisesRegex(ci.EvidenceError, 'every shard'):
            ci.inventory(self.root)

    def test_gate_cannot_borrow_verifier_from_a_later_job(self):
        path = self.root / '.github/workflows/ci.yml'
        verifier = 'python3 scripts/ci-shards.py verify --expected-revision "$GITHUB_SHA"'
        path.write_text(path.read_text().replace(verifier, 'python3 elsewhere.py verify') +
                        '\n  later:\n    run: ' + verifier + '\n')
        with self.assertRaisesRegex(ci.EvidenceError, 'source-bound receipts'):
            ci.inventory(self.root)

    def test_actual_shell_completion_rejects_missing_duplicate_or_reordered_phases(self):
        source = (self.root / 'ci.sh').read_text()
        function = re.search(r'^ci_complete_phase_coverage\(\) \{\n.*?^\}', source, re.M | re.S).group()
        for actual, expected in ((['one', 'two'], 0), (['one'], 1),
                                 (['one', 'one'], 1), (['two', 'one'], 1),
                                 (['one', 'two', 'three'], 1)):
            with self.subTest(actual=actual):
                script = function + '\nCI_PLANNED_PHASES=(one two)\nPHASE_NAMES=(' + ' '.join(actual) + ')\nci_complete_phase_coverage\n'
                result = subprocess.run(['bash', '-uc', script], capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_actual_shell_plan_lists_only_owned_parts(self):
        for shard in ci.SHARDS:
            result = subprocess.run(['bash', str(self.root / 'ci.sh'), '--shard', shard, '--list-phases'],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), ci.owned(self.config, shard))

    def test_actual_shell_unknown_shard_refuses_before_execution(self):
        result = subprocess.run(['bash', str(self.root / 'ci.sh'), '--shard', 'unknown'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('unknown CI shard', result.stderr)

    def test_actual_cli_verifies_source_bound_evidence(self):
        result = subprocess.run(['python3', str(self.root / 'scripts/ci-shards.py'), 'verify',
                                 '--expected-revision', self.revision, '--evidence', str(self.evidence),
                                 '--upstream-result', 'success'], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)['status'], 'success')


if __name__ == '__main__':
    unittest.main()

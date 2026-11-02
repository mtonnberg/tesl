"""Disk reclamation and ownership regressions for the migration runner cache."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('migration_go_cache', Path(__file__).with_name('migration-go-cache.py'))
cache_policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cache_policy)


class MigrationGoCache(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / 'cache'
        self.cache.mkdir()
        (self.cache / 'aa').mkdir()
        self.dependency = self.cache / 'aa/dependency-d'
        self.dependency.write_bytes(b'warmed dependency')

    def test_reclaims_generated_packages_and_keeps_dependencies_across_phases(self):
        cache_policy.seed(self.cache)
        for phase in range(3):
            generated = self.cache / f'aa/generated-{phase}-d'
            generated.write_bytes(b'x' * 1024)
            self.assertEqual(cache_policy.prune(self.cache), 1024)
            self.assertFalse(generated.exists())
            self.assertEqual(self.dependency.read_bytes(), b'warmed dependency')
        self.assertEqual(cache_policy.prune(self.cache), 0)

    def test_refuses_unmarked_shared_cache_without_deleting_files(self):
        with self.assertRaises(FileNotFoundError):
            cache_policy.prune(self.cache)
        self.assertTrue(self.dependency.exists())

    def test_refuses_marker_copied_to_another_cache(self):
        cache_policy.seed(self.cache)
        other = self.root / 'other'
        shutil.copytree(self.cache, other)
        with self.assertRaisesRegex(ValueError, 'ownership'):
            cache_policy.prune(other)
        self.assertTrue((other / 'aa/dependency-d').exists())

    def test_removes_links_without_touching_their_targets(self):
        cache_policy.seed(self.cache)
        outside = self.root / 'unrelated'
        outside.mkdir()
        victim = outside / 'keep'
        victim.write_text('unrelated data')
        (self.cache / 'directory-link').symlink_to(outside, target_is_directory=True)
        (self.cache / 'aa/file-link').symlink_to(victim)
        cache_policy.prune(self.cache)
        self.assertEqual(victim.read_text(), 'unrelated data')
        self.assertFalse((self.cache / 'directory-link').is_symlink())
        self.assertFalse((self.cache / 'aa/file-link').is_symlink())

    def test_cli_requires_explicit_matching_cache_and_leaves_other_files_alone(self):
        cache_policy.seed(self.cache)
        generated = self.cache / 'aa/generated-d'
        generated.write_text('still needed')
        command = [sys.executable, str(Path(cache_policy.__file__).resolve()), 'prune', str(self.cache)]
        for selected in (None, 'off', str(self.root / 'shared-cache')):
            with self.subTest(selected=selected):
                env = dict(os.environ)
                env.pop('GOCACHE', None)
                if selected is not None:
                    env['GOCACHE'] = selected
                result = subprocess.run(command, env=env, cwd=self.cache, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(generated.read_text(), 'still needed')
                self.assertEqual(self.dependency.read_bytes(), b'warmed dependency')

    def test_refuses_reseed_and_symlinked_cache_or_marker(self):
        cache_policy.seed(self.cache)
        with self.assertRaises(FileExistsError):
            cache_policy.seed(self.cache)
        link = self.root / 'link'
        link.symlink_to(self.cache, target_is_directory=True)
        with self.assertRaises(ValueError):
            cache_policy.prune(link)
        marker = self.cache / cache_policy.MARKER
        saved = self.root / 'saved-marker'
        marker.rename(saved)
        marker.symlink_to(saved)
        with self.assertRaises(ValueError):
            cache_policy.prune(self.cache)


if __name__ == '__main__':
    unittest.main()

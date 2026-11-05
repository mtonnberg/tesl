"""Source, executable and release-completeness guards for cross-major reuse."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('artifacts', Path(__file__).with_name('migration-ci-artifacts.py'))
artifacts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(artifacts)


class FixtureArtifacts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / 'bundle'
        self.payload = self.bundle / 'payload'
        for name in artifacts.required_files():
            file = self.payload / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(name)
            if name.endswith(('/app', '/api.test', '/app-test')):
                file.chmod(0o755)
        self.source = {'revision': 'a' * 40, 'tree': 'b' * 40, 'inputs_sha256': 'c' * 64, 'tracked_clean': True}
        self.tools = {'go': 'test compiler'}
        self.seal()

    def seal(self):
        self.manifest = {'version': 1, 'source': self.source, 'tools': self.tools,
                         'compiler_sha256': 'd' * 64,
                         'families': list(artifacts.FAMILIES), 'files': artifacts.inventory(self.payload),
                         'build_seconds': {key: 1 for key in ('compiler', 'cache-warm', *artifacts.FAMILIES)}}
        (self.bundle / artifacts.MANIFEST).write_text(json.dumps(self.manifest))

    def test_complete_bundle_and_relocated_copy(self):
        artifacts.verify(self.bundle, self.source, self.tools)
        output = self.root / 'consumer'
        evidence = self.root / 'evidence/reused.json'
        with mock.patch.object(artifacts, 'source_identity', return_value=self.source), \
             mock.patch.object(artifacts, 'tools', return_value=self.tools):
            artifacts.restore(self.bundle, output, evidence)
        self.assertTrue((output / 'twenty-releases/v20/api.test').is_file())
        self.assertTrue((output / 'review05-releases/queue/v4/app-test').stat().st_mode & 0o111)
        self.assertEqual(json.loads(evidence.read_text())['source'], self.source)

    def test_stale_sources_and_tools_refuse(self):
        for source, tools in ((dict(self.source, revision='d' * 40), self.tools),
                              (dict(self.source, inputs_sha256='e' * 64), self.tools),
                              (self.source, {'go': 'different compiler'})):
            with self.assertRaisesRegex(ValueError, 'identity differs'):
                artifacts.verify(self.bundle, source, tools)

    def test_changed_binary_mode_missing_or_extra_input_refuses(self):
        binary = self.payload / 'row/v1/app'
        original = binary.read_bytes()
        binary.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'changed'):
            artifacts.verify(self.bundle, self.source, self.tools)
        binary.write_bytes(original)
        binary.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'changed'):
            artifacts.verify(self.bundle, self.source, self.tools)
        binary.chmod(0o755)
        (self.payload / 'extra').write_text('unrecorded')
        with self.assertRaisesRegex(ValueError, 'changed'):
            artifacts.verify(self.bundle, self.source, self.tools)
        (self.payload / 'extra').unlink()
        binary.unlink()
        with self.assertRaisesRegex(ValueError, 'changed'):
            artifacts.verify(self.bundle, self.source, self.tools)

    def test_even_resealed_bundle_cannot_omit_release_or_execute_bits(self):
        (self.payload / 'twenty/v20/api.test').unlink()
        self.seal()
        with self.assertRaisesRegex(ValueError, 'omits required'):
            artifacts.verify(self.bundle, self.source, self.tools)

    def test_resealed_nonexecutable_and_invalid_timings_refuse(self):
        binary = self.payload / 'row/v1/app'
        binary.chmod(0o644)
        self.seal()
        with self.assertRaisesRegex(ValueError, 'executable mode'):
            artifacts.verify(self.bundle, self.source, self.tools)
        binary.chmod(0o755)
        self.seal()
        self.manifest['build_seconds']['row'] = -1
        (self.bundle / artifacts.MANIFEST).write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, 'nonnegative'):
            artifacts.verify(self.bundle, self.source, self.tools)

    def test_symlink_refuses(self):
        (self.payload / 'escape').symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, 'regular files'):
            artifacts.verify(self.bundle, self.source, self.tools)

    def test_source_change_during_copy_refuses_receipt(self):
        evidence = self.root / 'receipt.json'
        with mock.patch.object(artifacts, 'source_identity', side_effect=[self.source, {}]), \
             mock.patch.object(artifacts, 'tools', return_value=self.tools):
            with self.assertRaisesRegex(ValueError, 'changed during'):
                artifacts.restore(self.bundle, self.root / 'out', evidence)
        self.assertFalse(evidence.exists())


if __name__ == '__main__':
    unittest.main()

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import native_windows_tools as tools


class WindowsBuildToolsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='windows tool test å ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bash = self.root / 'cygwin/bin/bash.exe'
        self.bash.parent.mkdir(parents=True)
        self.bash.write_text('fixture')
        self.bash.with_name('cygpath.exe').write_text('fixture')
        self.plan = {'version': 1, 'windowsBuildTools': {name: {'version': '1.2.3', 'hash': name} for name in tools.NAMES}}
        self.archives = {name: self.root / (name + '.tar.gz') for name in tools.NAMES}

    def test_source_root_requires_one_expected_root(self):
        directory = self.root / 'source'
        directory.mkdir()
        with self.assertRaisesRegex(ValueError, 'unique root'):
            tools.source_root(directory, 'meson.py')
        (directory / 'nested').mkdir()
        expected = directory / 'nested/meson.py'
        expected.touch()
        self.assertEqual(tools.source_root(directory, 'meson.py'), expected.parent)
        (directory / 'other').mkdir()
        with self.assertRaises(ValueError):
            tools.source_root(directory, 'meson.py')

    def test_only_native_windows_and_complete_authoritative_pins_are_accepted(self):
        with patch.object(tools.sys, 'platform', 'linux'), self.assertRaisesRegex(ValueError, 'native Windows'):
            tools.provision(self.plan, self.archives, self.root / 'output', self.bash)
        with patch.object(tools.sys, 'platform', 'win32'):
            with self.assertRaisesRegex(ValueError, 'five'):
                tools.provision(self.plan, {}, self.root / 'output', self.bash)
            with self.assertRaisesRegex(ValueError, 'positive integer'):
                tools.provision(self.plan, self.archives, self.root / 'output', self.bash, 0)
            output = self.root / 'output'
            output.mkdir()
            (output / 'keep').write_text('keep')
            with self.assertRaisesRegex(ValueError, 'already exists'):
                tools.provision(self.plan, self.archives, output, self.bash)
            self.assertEqual((output / 'keep').read_text(), 'keep')

    def test_all_sources_are_verified_before_any_build_script_executes(self):
        events = []
        def extract(pin, archive, output, **options):
            events.append(pin['hash'])
            self.assertEqual(options, {'omit_symlinks_under': ('test cases',)} if pin['hash'] == 'meson' else {})
            output.mkdir()
            sentinel = {'meson': 'meson.py', 'ninja': 'configure.py', 'perl': 'win32/Makefile'}.get(pin['hash'], 'configure')
            path = output / sentinel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
            return output
        def run(*arguments, **kwargs):
            self.assertEqual(events, list(tools.NAMES))
            raise RuntimeError('stop before building')
        with patch.object(tools.sys, 'platform', 'win32'), patch.object(tools.shutil, 'which', return_value='MSVC'), \
                patch.object(tools, 'extract_verified', side_effect=extract), patch.object(tools, 'run', side_effect=run):
            with self.assertRaisesRegex(RuntimeError, 'stop before'):
                tools.provision(self.plan, self.archives, self.root / 'output', self.bash)
        self.assertFalse((self.root / 'output').exists())
        self.assertFalse(list(self.root.glob('.tesl-win-tools-*')))

    def test_cygwin_build_paths_remain_arguments_and_only_bison_enables_relocation(self):
        native_paths = [self.root / 'source with spaces', self.root / 'build', self.root / 'prefix $literal']
        with patch.object(tools, 'cygwin_path', side_effect=['/source with spaces', '/build', '/prefix $literal']), \
                patch.object(tools, 'run') as run:
            tools.build_cygwin('bison', *native_paths, self.bash, {}, 3)
        command = run.call_args.args[0]
        self.assertEqual(command[-5:], ['/source with spaces', '/build', '/prefix $literal', '3', 'bison'])
        self.assertIn('"$1/configure" "--prefix=$3"', command[4])
        self.assertIn('--enable-relocatable', command[4])
        self.assertNotIn(str(native_paths[0]), command[4])

    def test_source_builds_publish_verified_tool_paths_and_source_evidence(self):
        def extract(pin, archive, output, **options):
            output.mkdir()
            name = pin['hash']
            sentinel = {'meson': 'meson.py', 'ninja': 'configure.py', 'perl': 'win32/Makefile'}.get(name, 'configure')
            path = output / sentinel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
            (output / 'COPYING').write_text('upstream license')
            if name == 'meson':
                (output / 'mesonbuild').mkdir()
                (output / 'mesonbuild/mesonmain.py').write_text('runtime')
                (output / 'test cases').mkdir()
                (output / 'test cases/fixture').write_text('not needed at runtime')
            return output
        calls = []
        def run(command, directory, environment, capture=False, timeout=1800):
            command = list(map(str, command))
            calls.append(command)
            if command[-1] == 'uname -s':
                return 'CYGWIN_NT-10.0'
            if '--bootstrap' in command:
                (directory / 'ninja.exe').touch()
            if command[0] == 'nmake.exe' and command[-1] == 'installbare':
                prefix = Path(next(item[9:] for item in command if item.startswith('INST_TOP=')))
                (prefix / 'bin').mkdir(parents=True)
                (prefix / 'bin/perl.exe').touch()
            if command[-1] in ('--version', 'print $^V'):
                return '1.2.3'
            if command[-1] == 'print $Config{osname}':
                return 'MSWin32'
        def cygwin(name, source, build, prefix, bash, environment, jobs):
            (prefix / 'bin').mkdir(parents=True)
            (prefix / ('bin/' + name + '.exe')).touch()
        output = self.root / 'output'
        with patch.object(tools.sys, 'platform', 'win32'), patch.object(tools.shutil, 'which', return_value='MSVC'), \
                patch.object(tools, 'extract_verified', side_effect=extract), patch.object(tools, 'run', side_effect=run), \
                patch.object(tools, 'build_cygwin', side_effect=cygwin):
            commands = tools.provision(self.plan, self.archives, output, self.bash)
        self.assertEqual(commands, tools.command_paths(output))
        self.assertTrue(all(Path(command[-1]).is_file() for command in commands.values()))
        metadata = json.loads((output / 'native-build.json').read_text())
        self.assertEqual(metadata['sources'], self.plan['windowsBuildTools'])
        self.assertFalse(metadata['runtime_payload'])
        self.assertEqual(sum(command[0] == 'nmake.exe' for command in calls), 2)
        self.assertTrue(any('CCTYPE=MSVC143' in command for command in calls))
        self.assertEqual((output / 'meson/mesonbuild/mesonmain.py').read_text(), 'runtime')
        self.assertEqual((output / 'meson/COPYING').read_text(), 'upstream license')
        self.assertFalse((output / 'meson/test cases').exists())


if __name__ == '__main__':
    unittest.main()

"""The native gate must report all suite failures without accepting a partial pass."""

from contextlib import redirect_stdout
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("native_parity", Path(__file__).with_name("native-parity.py"))
native_parity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native_parity)


class NativeChecksTest(unittest.TestCase):
    def test_generated_snapshots_must_match_committed_bytes(self):
        with tempfile.TemporaryDirectory(prefix="tesl snapshots å ") as temporary:
            root = Path(temporary)
            environment = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
            def git(*args):
                subprocess.run(["git", "-c", "user.name=Snapshot test", "-c", "user.email=test@example.invalid",
                                "-c", "core.autocrlf=false", *args], cwd=root, env=environment,
                               check=True, capture_output=True, timeout=30)
            git("init", "--quiet")
            names = ("compiler/lib/embedded_docs.ml",
                     "compiler/lib/go_runtime/embedded/embedded_go_runtime.ml")
            content = b'let files = [("source", "line\\n")];;\n'
            for name in names:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            git("add", ".")
            git("commit", "--quiet", "-m", "fixture")
            native_parity.verify_generated_snapshots(root, environment)
            # Outer newline conversion, embedded CRLF bytes, content changes,
            # truncation and appended data must all fail before packaging.
            for name in names:
                for changed in (content.replace(b'\n', b'\r\n'), content.replace(b'\\n', b'\\r\\n'),
                                content.replace(b'line', b'changed'), content[:-1], content + b'extra',
                                b'x' * 100000):
                    with self.subTest(name=name, size=len(changed)):
                        (root / name).write_bytes(changed)
                        with self.assertRaises(SystemExit) as error:
                            native_parity.verify_generated_snapshots(root, environment)
                        self.assertIn(name, str(error.exception))
                        self.assertIn("first difference at byte", str(error.exception))
                        self.assertLess(len(str(error.exception)), 600)
                    (root / name).write_bytes(content)
            (root / names[0]).unlink()
            with self.assertRaises(FileNotFoundError):
                native_parity.verify_generated_snapshots(root, environment)

    def test_success_runs_every_check_with_its_directory_and_environment(self):
        checks = [("first", ["tool", "literal space"], Path("one")),
                  ("second", ["other", "å"], Path("two"))]
        environment = {"PATH": "selected tools"}
        with patch.object(native_parity, "run") as run, redirect_stdout(io.StringIO()):
            native_parity.run_checks(checks, environment)
        self.assertEqual(run.call_args_list, [unittest.mock.call(args, directory, environment)
                                             for _, args, directory in checks])

    def test_reports_multiple_failures_after_running_the_later_suites(self):
        checks = [(name, [name], Path(".")) for name in ("compiler", "LSP", "editor")]
        failures = [subprocess.CalledProcessError(1, ["compiler"]),
                    subprocess.CalledProcessError(2, ["LSP"]), None]
        output = io.StringIO()
        with patch.object(native_parity, "run", side_effect=failures) as run, redirect_stdout(output):
            with self.assertRaisesRegex(SystemExit, "Native portability failed: compiler, LSP"):
                native_parity.run_checks(checks, {})
        self.assertEqual(run.call_count, 3)
        self.assertIn("Native check: editor", output.getvalue())

    def test_missing_executable_does_not_hide_later_results(self):
        checks = [("missing", ["missing"], Path(".")), ("editor", ["node"], Path("."))]
        with patch.object(native_parity, "run", side_effect=[FileNotFoundError("missing"), None]) as run:
            with redirect_stdout(io.StringIO()), self.assertRaisesRegex(SystemExit, "failed: missing"):
                native_parity.run_checks(checks, {})
        self.assertEqual(run.call_count, 2)

    def test_real_failed_process_still_runs_the_following_process(self):
        with tempfile.TemporaryDirectory(prefix="tesl native å ") as directory:
            checks = [
                ("failure", [sys.executable, "-c", "raise SystemExit(7)"], directory),
                ("following", [sys.executable, "-c",
                 "from pathlib import Path; Path('executed').write_text('yes')"], directory),
            ]
            with redirect_stdout(io.StringIO()), self.assertRaisesRegex(SystemExit, "failed: failure"):
                native_parity.run_checks(checks, os.environ.copy())
            self.assertEqual((Path(directory) / "executed").read_text(), "yes")


if __name__ == "__main__":
    unittest.main()

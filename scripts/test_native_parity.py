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

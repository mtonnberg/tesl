"""The local runner must not leave provider/build children after a timeout."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("rolling_run", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerCleanup(unittest.TestCase):
    def test_timeout_signals_descendant_and_remains_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "child-stopped"
            child = '''import pathlib, signal, sys, time
def stop(signum, frame):
    pathlib.Path(sys.argv[1]).write_text("terminated")
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
time.sleep(60)
'''
            parent = "import subprocess, sys, time; subprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2]]); time.sleep(60)"
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.run([sys.executable, "-c", parent, child, marker], timeout=2)
            self.assertEqual(marker.read_text(), "terminated")


if __name__ == "__main__":
    unittest.main()

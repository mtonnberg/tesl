"""Release inputs must have the same bytes under Windows Git line endings."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class CheckoutTests(unittest.TestCase):
    def test_embedded_runtime_and_locks_ignore_autocrlf(self):
        repository = Path(__file__).resolve().parent.parent
        for autocrlf in ("true", "false", "input"):
            with self.subTest(autocrlf=autocrlf), tempfile.TemporaryDirectory(prefix="tesl checkout å ") as temporary:
                root = Path(temporary)
                environment = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
                def git(*arguments):
                    subprocess.run(["git", "-c", "core.autocrlf=" + autocrlf, "-c", "core.safecrlf=false", *arguments],
                                   cwd=root, env=environment, check=True, capture_output=True, timeout=30)
                git("init", "--quiet")
                shutil.copyfile(repository / ".gitattributes", root / ".gitattributes")
                paths = ("runtime/go/go.mod", "runtime/go/go.sum", "runtime/go/teslrt/example.go",
                         "runtime/go/teslrt/example_windows.go", "compiler/lib/go_runtime/embedded/embedded_go_runtime.ml")
                content = b"first line\nsecond line\n"
                for name in (*paths, "control.txt"):
                    path = root / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(content)
                git("add", ".")
                # Checkout-index creates a fresh working tree from the index;
                # it exercises conversion without touching the actual repo.
                checkout = root / "fresh"
                git("checkout-index", "--all", "--prefix=" + str(checkout) + os.sep)
                for name in paths:
                    self.assertEqual((checkout / name).read_bytes(), content, name)
                expected_control = content.replace(b"\n", b"\r\n") if autocrlf == "true" else content
                self.assertEqual((checkout / "control.txt").read_bytes(), expected_control)


if __name__ == "__main__":
    unittest.main()

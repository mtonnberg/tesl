import os
from pathlib import Path
import shutil
import tempfile
import unittest

from native_msvc import prefer_msvc


class NativeMSVCTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="native MSVC å ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cygwin = self.root / "Cygwin/bin"
        self.msvc = self.root / "Visual Studio/bin"
        for directory, names in ((self.cygwin, ("link.exe",)),
                                 (self.msvc, ("cl.exe", "link.exe", "nmake.exe"))):
            directory.mkdir(parents=True)
            for name in names:
                path = directory / name
                path.write_bytes(b"fixture")
                path.chmod(0o755)

    def test_compiler_and_linker_resolve_from_the_same_native_directory(self):
        original = {"PATH": os.pathsep.join(map(str, (self.cygwin, self.msvc))),
                    "INCLUDE": "selected SDK", "LIB": "selected libraries"}
        self.assertEqual(shutil.which("link.exe", path=original["PATH"]), str(self.cygwin / "link.exe"))
        compiler = shutil.which("cl.exe", path=original["PATH"])
        selected = prefer_msvc(original, compiler)
        self.assertEqual(shutil.which("link.exe", path=selected["PATH"]), str(self.msvc / "link.exe"))
        self.assertEqual(shutil.which("nmake.exe", path=selected["PATH"]), str(self.msvc / "nmake.exe"))
        self.assertTrue(selected["PATH"].endswith(original["PATH"]))
        self.assertEqual(selected["INCLUDE"], original["INCLUDE"])
        self.assertEqual(selected["LIB"], original["LIB"])
        self.assertTrue(original["PATH"].startswith(str(self.cygwin)))

    def test_missing_native_linker_never_falls_back_to_cygwin(self):
        (self.msvc / "link.exe").unlink()
        with self.assertRaisesRegex(ValueError, "link.exe.*beside cl.exe"):
            prefer_msvc({"PATH": str(self.cygwin)}, self.msvc / "cl.exe")


if __name__ == "__main__":
    unittest.main()

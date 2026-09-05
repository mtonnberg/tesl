"""Exercise the actual Windows signature check before expensive source builds."""

import os
from pathlib import Path
import sys
import unittest

from native_compiler_tools import microsoft_runtime_identity


@unittest.skipUnless(sys.platform == "win32" and os.environ.get("TESL_TEST_MSVC_RUNTIME") == "1",
                     "requires the native MSVC runtime integration job")
class NativeWindowsRuntimeTests(unittest.TestCase):
    def test_signature_inspection_ignores_inherited_powershell_module_paths(self):
        environment = {key.upper(): value for key, value in os.environ.items()}
        self.assertIn("VCTOOLSREDISTDIR", environment)
        runtime = Path(environment["VCTOOLSREDISTDIR"]) / "x64/Microsoft.VC143.CRT/vcruntime140.dll"
        self.assertTrue(runtime.is_file(), str(runtime))
        # Models pwsh -> Python -> powershell.exe, including an unusable module
        # path. The signature helper must discover Windows PowerShell's modules.
        environment["PSMODULEPATH"] = str(runtime.parent / "not-a-powershell-module-directory")
        identity = microsoft_runtime_identity(runtime, environment)
        self.assertEqual(identity["status"], "Valid")
        self.assertIn("CN=Microsoft Corporation", identity["signer"])


if __name__ == "__main__":
    unittest.main()

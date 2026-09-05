import hashlib
from pathlib import Path
import tempfile
import unittest
import zipfile

import installer_artifact as setup


class SetupArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tesl setup å ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bootstrap = self.root / "installer.exe"
        self.bootstrap.write_bytes(b"MZ" + b"native bootstrap" * 20)
        self.archive = self.root / "portable.zip"
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("tesl-version/fixture", "validated payload")
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.output = self.root / "setup.exe"

    def test_footer_offsets_and_checksums_identify_exact_tested_zip(self):
        digest = setup.bundle(self.bootstrap, self.archive, self.digest, self.output)
        data = self.output.read_bytes()
        magic, offset, length, embedded_hash = setup.FOOTER.unpack(data[-64:])
        self.assertEqual(magic, b"TESL-INSTALL-V1\0")
        self.assertEqual(offset, self.bootstrap.stat().st_size)
        self.assertEqual(data[:offset], self.bootstrap.read_bytes())
        self.assertEqual(data[offset:offset + length], self.archive.read_bytes())
        self.assertEqual(offset + length + 64, len(data))
        self.assertEqual(embedded_hash.hex(), self.digest)
        self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
        other = self.root / "again.exe"
        self.assertEqual(setup.bundle(self.bootstrap, self.archive, self.digest, other), digest)

    def test_bad_checksum_never_emits_setup(self):
        with self.assertRaisesRegex(ValueError, "checksum"):
            setup.bundle(self.bootstrap, self.archive, "0" * 64, self.output)
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.glob(".tesl-setup-*")))

    def test_existing_outputs_and_embedded_bootstraps_are_rejected(self):
        setup.bundle(self.bootstrap, self.archive, self.digest, self.output)
        preserved = self.output.read_bytes()
        with self.assertRaisesRegex(ValueError, "already exists"):
            setup.bundle(self.bootstrap, self.archive, self.digest, self.output)
        with self.assertRaisesRegex(ValueError, "already has"):
            setup.bundle(self.output, self.archive, self.digest, self.root / "nested.exe")
        self.assertEqual(self.output.read_bytes(), preserved)

    def test_non_windows_bootstrap_and_non_zip_payload_are_rejected(self):
        self.bootstrap.write_bytes(b"ELF")
        with self.assertRaisesRegex(ValueError, "Windows executable"):
            setup.bundle(self.bootstrap, self.archive, self.digest, self.output)
        self.bootstrap.write_bytes(b"MZfake")
        self.archive.write_bytes(b"not zip")
        with self.assertRaisesRegex(ValueError, "portable ZIP"):
            setup.bundle(self.bootstrap, self.archive, hashlib.sha256(self.archive.read_bytes()).hexdigest(), self.output)


if __name__ == "__main__":
    unittest.main()

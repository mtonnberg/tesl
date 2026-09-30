"""Source pin verification must happen before any build tool executes."""

import base64
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from native_source import digest_bytes, extract_verified, nar_hash, portable_member


def sri(digest):
    return "sha256-" + base64.b64encode(digest).decode("ascii")


def archive_file(path, entries, mode="w:gz"):
    with tarfile.open(path, mode) as archive:
        for name, content, kind, permissions in entries:
            info = tarfile.TarInfo(name)
            info.type, info.mode = kind, permissions
            info.size = len(content) if kind == tarfile.REGTYPE else 0
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                info.linkname = content.decode()
            archive.addfile(info, io.BytesIO(content) if info.isfile() else None)


class NativeSourceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="native source å ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "source.tar.gz"
        self.entries = [("root/configure", b"#!/bin/sh\n", tarfile.REGTYPE, 0o755),
                        ("root/nested/data", b"data", tarfile.REGTYPE, 0o644)]
        archive_file(self.archive, self.entries)
        self.metadata = {"hashAlgorithm": "sha256", "hashMode": "flat", "stripRoot": True,
                         "hash": sri(hashlib.sha256(self.archive.read_bytes()).digest())}

    def test_flat_source_authenticates_archive_and_strips_root(self):
        source = extract_verified(self.metadata, self.archive, self.root / "output")
        self.assertEqual((source / "nested/data").read_bytes(), b"data")
        self.assertTrue((source / "configure").stat().st_mode & 0o100)
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["output", "source.tar.gz"])

    def test_flat_hash_with_root_retained_and_xz_archive(self):
        archive_file(self.archive, self.entries, mode="w:xz")
        self.metadata.update(stripRoot=False, hash=sri(hashlib.sha256(self.archive.read_bytes()).digest()))
        source = extract_verified(self.metadata, self.archive, self.root / "output")
        self.assertEqual((source / "root/nested/data").read_bytes(), b"data")

    def test_recursive_hash_ignores_archive_order_container_and_nonexecutability_modes(self):
        original = extract_verified(self.metadata, self.archive, self.root / "first")
        self.metadata.update(hashMode="recursive", hash=sri(nar_hash(original)))
        archive_file(self.archive, [(name, data, kind, mode | 0o020) for name, data, kind, mode in reversed(self.entries)], mode="w:xz")
        second = extract_verified(self.metadata, self.archive, self.root / "second")
        self.assertEqual(nar_hash(original), nar_hash(second))

    def test_recursive_hash_authenticates_content_filename_and_executable_bit(self):
        original = extract_verified(self.metadata, self.archive, self.root / "first")
        self.metadata.update(hashMode="recursive", hash=sri(nar_hash(original)))
        mutations = [("root/configure", b"changed", tarfile.REGTYPE, 0o755),
                     ("root/different", b"#!/bin/sh\n", tarfile.REGTYPE, 0o755),
                     ("root/configure", b"#!/bin/sh\n", tarfile.REGTYPE, 0o644)]
        for entry in mutations:
            with self.subTest(entry=entry):
                archive_file(self.archive, [entry, self.entries[1]])
                with self.assertRaisesRegex(ValueError, "tree checksum mismatch"):
                    extract_verified(self.metadata, self.archive, self.root / "output")
                self.assertFalse((self.root / "output").exists())
                self.assertFalse(list(self.root.glob(".tesl-source-*")))

    def test_recursive_verification_uses_archive_modes_when_chmod_cannot_set_executable(self):
        original = extract_verified(self.metadata, self.archive, self.root / "first")
        self.metadata.update(hashMode="recursive", hash=sri(nar_hash(original)))
        with patch.object(Path, "chmod"):
            source = extract_verified(self.metadata, self.archive, self.root / "output")
        self.assertEqual(nar_hash(source, {"configure"}), nar_hash(original))
        (source / "configure").chmod(0o644)
        self.assertEqual(nar_hash(source, {"configure"}), nar_hash(original))

    def test_windows_paths_reject_ads_devices_trailing_aliases_and_case_collisions(self):
        for name in ("root/file:stream", "C:/file", "root/NUL.txt", "root/COM1", "root/Lpt9.c",
                     "root/file.", "root/file ", 'root/file?name', 'root/file<name'):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "portable Windows"):
                portable_member(name, set())
        with self.assertRaisesRegex(ValueError, "case-insensitive duplicate"):
            portable_member("root/Makefile", {"root/makefile"})
        portable_member("root/compiler.c", {"root/other.c"})

    def test_bad_flat_checksum_does_not_extract(self):
        self.archive.write_bytes(b"not even a tarball")
        with self.assertRaisesRegex(ValueError, "archive checksum mismatch"):
            extract_verified(self.metadata, self.archive, self.root / "output")
        self.assertFalse((self.root / "output").exists())

    def test_unsafe_paths_duplicate_links_and_special_files_rejected(self):
        invalid = [("../outside", b"", tarfile.REGTYPE, 0o644),
                   ("/absolute", b"", tarfile.REGTYPE, 0o644),
                   ("root/../escape", b"", tarfile.REGTYPE, 0o644),
                   ("root/./dot", b"", tarfile.REGTYPE, 0o644),
                   ("root//empty", b"", tarfile.REGTYPE, 0o644),
                   ("root\\escape", b"", tarfile.REGTYPE, 0o644),
                   ("root/link", b"../outside", tarfile.SYMTYPE, 0o644),
                   ("root/link", b"root/configure", tarfile.LNKTYPE, 0o644),
                   ("root/device", b"", tarfile.CHRTYPE, 0o644), self.entries[0]]
        for entry in invalid:
            with self.subTest(entry=entry):
                archive_file(self.archive, self.entries + [entry])
                self.metadata["hash"] = sri(hashlib.sha256(self.archive.read_bytes()).digest())
                with self.assertRaisesRegex(ValueError, "unsafe or duplicate"):
                    extract_verified(self.metadata, self.archive, self.root / "output")
                self.assertFalse((self.root / "output").exists())
                self.assertFalse((self.root / "outside").exists())

    def test_single_root_and_nonempty_archive_required(self):
        for entries in ([], [("one/file", b"", tarfile.REGTYPE, 0o644),
                             ("two/file", b"", tarfile.REGTYPE, 0o644)],
                        [("file", b"", tarfile.REGTYPE, 0o644)]):
            with self.subTest(entries=entries):
                archive_file(self.archive, entries)
                self.metadata["hash"] = sri(hashlib.sha256(self.archive.read_bytes()).digest())
                with self.assertRaises(ValueError):
                    extract_verified(self.metadata, self.archive, self.root / "output")

    def test_omitted_test_links_are_authenticated_without_creating_or_following_them(self):
        original = extract_verified(self.metadata, self.archive, self.root / "first")
        (original / "test cases").mkdir()
        links = {"test cases/link": "../../outside", "test cases/other": "link"}
        self.metadata.update(hashMode="recursive", hash=sri(nar_hash(original, symlink_targets=links)))
        entries = self.entries + [("root/" + name, target.encode(), tarfile.SYMTYPE, 0o777)
                                  for name, target in links.items()]
        archive_file(self.archive, entries)
        output = extract_verified(self.metadata, self.archive, self.root / "output",
                                  omit_symlinks_under=("test cases",))
        self.assertEqual((output / "nested/data").read_bytes(), b"data")
        self.assertEqual(list((output / "test cases").iterdir()), [])
        self.assertFalse((self.root / "outside").exists())
        # An omitted link is still source: changing its target or name must fail.
        for changed in (("root/test cases/link", b"other", tarfile.SYMTYPE, 0o777),
                        ("root/test cases/renamed", b"../../outside", tarfile.SYMTYPE, 0o777)):
            with self.subTest(changed=changed):
                archive_file(self.archive, self.entries + [changed, entries[-1]])
                with self.assertRaisesRegex(ValueError, "tree checksum mismatch"):
                    extract_verified(self.metadata, self.archive, self.root / "changed",
                                     omit_symlinks_under=("test cases",))
                self.assertFalse((self.root / "changed").exists())

    def test_link_omission_is_narrow_and_rejects_link_children_in_either_order(self):
        self.metadata.update(hashMode="recursive")
        link = ("root/test cases/link", b"../nested", tarfile.SYMTYPE, 0o777)
        child = ("root/test cases/link/file", b"data", tarfile.REGTYPE, 0o644)
        cases = [[("root/runtime/link", b"../nested", tarfile.SYMTYPE, 0o777)],
                 [("root/test cases/link", b"root/nested/data", tarfile.LNKTYPE, 0o644)],
                 [link, child], [child, link], [link, link]]
        for entries in cases:
            with self.subTest(entries=entries):
                archive_file(self.archive, self.entries + entries)
                with self.assertRaisesRegex(ValueError, "unsafe or duplicate|collides"):
                    extract_verified(self.metadata, self.archive, self.root / "output",
                                     omit_symlinks_under=("test cases",))
                self.assertFalse((self.root / "output").exists())

    def test_link_omission_requires_explicit_hash_and_directory_contract(self):
        for metadata in (self.metadata, dict(self.metadata, hashMode="recursive", stripRoot=False)):
            with self.assertRaisesRegex(ValueError, "recursive stripRoot"):
                extract_verified(metadata, self.archive, self.root / "output", omit_symlinks_under=("tests",))
        for names in ("tests", ("",), (".",), ("..",), ("../tests",), ("tests/links",), ("tests\\links",), (None,)):
            with self.subTest(names=names), self.assertRaisesRegex(ValueError, "top-level names"):
                extract_verified(self.metadata, self.archive, self.root / "output", omit_symlinks_under=names)

    def test_virtual_link_metadata_cannot_be_ignored_or_shadow_a_real_file(self):
        source = extract_verified(self.metadata, self.archive, self.root / "output")
        for links, message in (({"missing/link": "target"}, "parent is missing"),
                               ({"nested/data": "target"}, "collides"),
                               ({"../outside": "target"}, "invalid omitted")):
            with self.subTest(links=links), self.assertRaisesRegex(ValueError, message):
                nar_hash(source, symlink_targets=links)

    def test_metadata_requires_explicit_supported_hash_semantics(self):
        for key, value in (("hashAlgorithm", "sha512"), ("hashMode", None),
                           ("hashMode", "nar"), ("stripRoot", None), ("stripRoot", "yes")):
            with self.subTest(key=key, value=value):
                metadata = dict(self.metadata, **{key: value})
                with self.assertRaises(ValueError):
                    extract_verified(metadata, self.archive, self.root / "output")
        for value in (None, "sha256-notbase64", "sha256-AA==", "sha512-" + "A" * 44):
            with self.subTest(value=value), self.assertRaises(ValueError):
                digest_bytes(value)

    def test_existing_output_is_preserved_including_dangling_symlink(self):
        output = self.root / "output"
        output.mkdir()
        (output / "keep").write_text("keep")
        with self.assertRaisesRegex(ValueError, "already exists"):
            extract_verified(self.metadata, self.archive, output)
        self.assertEqual((output / "keep").read_text(), "keep")
        if os.name != "nt":
            link = self.root / "link"
            link.symlink_to(self.root / "missing")
            with self.assertRaisesRegex(ValueError, "already exists"):
                extract_verified(self.metadata, self.archive, link)
            self.assertTrue(link.is_symlink())

    def test_compressed_and_expanded_size_limits(self):
        with patch("native_source.MAX_SOURCE_BYTES", 2):
            with self.assertRaisesRegex(ValueError, "archive is too large"):
                extract_verified(self.metadata, self.archive, self.root / "output")
        archive_file(self.archive, [("root/large", b"0" * 10000, tarfile.REGTYPE, 0o644)])
        self.metadata["hash"] = sri(hashlib.sha256(self.archive.read_bytes()).digest())
        with patch("native_source.MAX_SOURCE_BYTES", 1000):
            with self.assertRaisesRegex(ValueError, "expanded source archive is too large"):
                extract_verified(self.metadata, self.archive, self.root / "output")

    @unittest.skipUnless(shutil.which("nix") and os.name != "nt", "Nix interoperability needs Nix on Unix")
    def test_nar_hash_matches_nix_on_real_directory(self):
        source = extract_verified(self.metadata, self.archive, self.root / "output")
        # Include empty directories, names requiring byte-order sorting and
        # payloads on both sides of the eight-byte NAR padding boundary.
        (source / "empty").mkdir()
        for name, length in (("å", 7), ("Z", 8), ("a", 9)):
            (source / name).write_bytes(b"x" * length)
        result = subprocess.run(["nix", "--extra-experimental-features", "nix-command",
                                 "hash", "path", str(source)], check=True, capture_output=True, text=True)
        self.assertEqual(result.stdout.strip(), sri(nar_hash(source)))
        # Nix is the independent oracle for virtual links, including dangling
        # and directory targets. No Windows symlink privilege is needed to hash.
        links = {"empty/link": "../nested", "external": "../../missing", "å-link": "å"}
        for name, target in links.items():
            (source / name).symlink_to(target)
        result = subprocess.run(["nix", "--extra-experimental-features", "nix-command",
                                 "hash", "path", str(source)], check=True, capture_output=True, text=True)
        for name in links:
            (source / name).unlink()
        self.assertEqual(result.stdout.strip(), sri(nar_hash(source, symlink_targets=links)))


if __name__ == "__main__":
    unittest.main()

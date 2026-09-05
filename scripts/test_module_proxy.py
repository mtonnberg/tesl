"""Module bundle checks use generated fixtures, never live downloads."""

from contextlib import contextmanager
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

import module_proxy as bundle


def zip_bytes(files, reverse=False, year=2000, compression=zipfile.ZIP_STORED):
    result = io.BytesIO()
    with zipfile.ZipFile(result, "w", compression=compression) as archive:
        for name, data in sorted(files, reverse=reverse):
            info = zipfile.ZipInfo(name, date_time=(year, 1, 1, 0, 0, 0))
            info.compress_type = compression
            archive.writestr(info, data)
    return result.getvalue()


@contextmanager
def fixture():
    with tempfile.TemporaryDirectory(prefix="tesl modules å ") as temporary:
        root = Path(temporary)
        module, version = "example.com/Hello", "v1.2.3"
        mod = b"module example.com/Hello\n\ngo 1.18\n"
        files = [(f"{module}@{version}/go.mod", mod),
                 (f"{module}@{version}/hello.go", b"package hello\nconst Answer = 42\n"),
                 (f"{module}@{version}/LICENSE", b"Fixture license\n")]
        sums = f"{module} {version} {bundle.h1(files)}\n{module} {version}/go.mod {bundle.h1([('go.mod', mod)])}\n"
        locks = {bundle.LOCKS[0]: b"module consumer\n\ngo 1.18\n\nrequire example.com/Hello v1.2.3\n",
                 bundle.LOCKS[1]: sums.encode()}
        for name, data in locks.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        plan = {"version": 1, "toolchainVersion": "0.3.1-test", "sourceRevision": "a" * 40,
                "moduleInputs": list(bundle.LOCKS), "moduleInputHashes": {name: bundle.sha256(data) for name, data in locks.items()}}
        stem = f"{bundle.escaped(module)}/@v/{version}"
        source = {stem + ".mod": mod, stem + ".zip": zip_bytes(files)}
        yield root, plan, source, files


class ModuleProxyTest(unittest.TestCase):
    def test_inventory_paths_checksums_and_licenses(self):
        with fixture() as (root, plan, source, _):
            output = root / "output with spaces å"
            inventory = bundle.build(plan, root, output, source.__getitem__)
            self.assertEqual(inventory["module_inputs"], plan["moduleInputHashes"])
            self.assertEqual(inventory["source_revision"], "a" * 40)
            self.assertEqual(len(inventory["modules"]), 1)
            item = inventory["modules"][0]
            self.assertEqual(item["path"], "example.com/Hello")
            self.assertEqual(item["licenses"], ["licenses/example.com/!hello@v1.2.3/LICENSE"])
            self.assertEqual((output / item["licenses"][0]).read_bytes(), b"Fixture license\n")
            self.assertEqual(json.loads((output / "proxy/example.com/!hello/@v/v1.2.3.info").read_bytes()), {"Version": "v1.2.3"})
            for name, info in inventory["files"].items():
                data = (output / name).read_bytes()
                self.assertEqual(info, {"bytes": len(data), "sha256": bundle.sha256(data)})
            self.assertEqual({p.relative_to(output).as_posix() for p in output.rglob("*") if p.is_file()},
                             set(inventory["files"]) | {"inventory.json"})

    def test_rebuilds_ignore_zip_compression_order_and_timestamps(self):
        with fixture() as (root, plan, source, files):
            one, two = root / "one", root / "two"
            bundle.build(plan, root, one, source.__getitem__)
            source[next(key for key in source if key.endswith(".zip"))] = zip_bytes(files, reverse=True, year=2025, compression=zipfile.ZIP_DEFLATED)
            bundle.build(plan, root, two, source.__getitem__)
            for path in one.rglob("*"):
                if path.is_file():
                    self.assertEqual(path.read_bytes(), (two / path.relative_to(one)).read_bytes())

    def test_corrupt_mod_zip_and_missing_download_leave_no_output(self):
        for kind in ("mod", "zip", "missing"):
            with self.subTest(kind=kind), fixture() as (root, plan, source, files):
                if kind == "zip":
                    changed = files + [("example.com/Hello@v1.2.3/extra.go", b"changed")]
                    source[next(key for key in source if key.endswith(".zip"))] = zip_bytes(changed)
                elif kind == "mod":
                    source[next(key for key in source if key.endswith(".mod"))] += b"// changed\n"
                else:
                    del source[next(key for key in source if key.endswith(".zip"))]
                output = root / "output"
                with self.assertRaises((ValueError, KeyError)):
                    bundle.build(plan, root, output, source.__getitem__)
                self.assertFalse(output.exists())
                self.assertEqual(list(root.glob(".tesl-modules-*")), [])

    def test_stale_or_missing_lock_hashes_fail_before_download(self):
        for kind in ("go.mod", "go.sum", "missing-hashes", "schema", "inputs"):
            with self.subTest(kind=kind), fixture() as (root, plan, source, _):
                if kind in ("go.mod", "go.sum"):
                    with (root / "runtime/go" / kind).open("ab") as stream:
                        stream.write(b"\n")
                elif kind == "missing-hashes":
                    del plan["moduleInputHashes"]
                elif kind == "schema":
                    plan["version"] = 2
                else:
                    plan["moduleInputs"] = ["../go.sum"]
                with self.assertRaises(ValueError):
                    bundle.build(plan, root, root / "output", lambda _: self.fail("downloaded stale inputs"))

    def test_existing_output_is_preserved(self):
        for directory in (True, False):
            with self.subTest(directory=directory), fixture() as (root, plan, source, _):
                output = root / "existing"
                if directory:
                    output.mkdir()
                    sentinel = output / "user-file"
                else:
                    sentinel = output
                sentinel.write_bytes(b"preserve")
                with self.assertRaises(FileExistsError):
                    bundle.build(plan, root, output, source.__getitem__)
                self.assertEqual(sentinel.read_bytes(), b"preserve")

    def test_go_mod_only_versions_are_bundled_without_unpinned_zip(self):
        with fixture() as (root, plan, source, _):
            lock = root / bundle.LOCKS[1]
            lock.write_bytes(b"\n".join(line for line in lock.read_bytes().splitlines() if b"/go.mod " in line) + b"\n")
            plan["moduleInputHashes"][bundle.LOCKS[1]] = bundle.sha256(lock.read_bytes())
            del source[next(key for key in source if key.endswith(".zip"))]
            inventory = bundle.build(plan, root, root / "output", source.__getitem__)
            self.assertEqual(inventory["modules"][0]["licenses"], [])
            self.assertFalse(any(path.endswith(".zip") for path in inventory["files"]))

    def test_invalid_archive_members_rejected_even_with_matching_hash(self):
        for name in ("other@v1.2.3/file", "example.com/Hello@v1.2.3/../escape", "example.com/Hello@v1.2.3/a\\b", "example.com/Hello@v1.2.3/a\nb"):
            with self.subTest(name=name):
                files = [(name, b"invalid")]
                with self.assertRaises(ValueError):
                    bundle.canonical_zip(zip_bytes(files), "example.com/Hello", "v1.2.3", bundle.h1(files))

    def test_malformed_locks_are_rejected(self):
        digest = bundle.h1([("go.mod", b"module example.com/ok\n")])
        valid = f"example.com/ok v1.0.0/go.mod {digest}"
        cases = ["", "invalid", valid + " extra", valid.replace("h1:", "h2:"),
                 valid.replace("example.com/ok", "../escape"), valid.replace("example.com/ok", "C:/escape"),
                 valid.replace("v1.0.0", "latest"), valid.replace("/go.mod", ""),
                 valid + "\n" + valid.replace(digest, "h1:" + "A" * 43 + "=")]
        for source in cases:
            with self.subTest(source=source), self.assertRaises(ValueError):
                bundle.parse_sums(source)

    def test_local_cache_reader_does_not_need_info_ziphash_or_locks(self):
        with fixture() as (root, plan, source, _):
            cache = root / "cache"
            for name, data in source.items():
                path = cache / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            bundle.build(plan, root, root / "output", bundle.source_reader(str(cache)))

    @unittest.skipUnless(shutil.which("go"), "Go required for independent checksum verification")
    def test_real_go_verifies_canonical_bundle_with_empty_cache_offline(self):
        with fixture() as (root, plan, source, _):
            output = root / "bundle"
            bundle.build(plan, root, output, source.__getitem__)
            env = dict(os.environ, GOENV="off", GOTOOLCHAIN="local", GOWORK="off", GOFLAGS="",
                       GO111MODULE="on", GOPROXY=(output / "proxy").as_uri(), GOSUMDB="off",
                       GOPRIVATE="", GONOPROXY="none", GOVCS="*:off", GOMODCACHE=str(root / "empty cache"))
            result = subprocess.run(["go", "mod", "download", "-json", "all"], cwd=root / "runtime/go", env=env,
                                    check=True, capture_output=True, text=True, timeout=60)
            downloaded = json.loads(result.stdout)
            self.assertEqual(downloaded["Sum"], bundle.parse_sums((root / bundle.LOCKS[1]).read_text())[("example.com/Hello", "v1.2.3")]["zip"])
            self.assertEqual(Path(downloaded["Dir"]).joinpath("hello.go").read_bytes(), b"package hello\nconst Answer = 42\n")


if __name__ == "__main__":
    unittest.main()

"""Payload assembly failures, archive contents, and metadata reproducibility."""

from contextlib import contextmanager
import copy
import json
import os
from pathlib import Path
import tarfile
import unittest
from unittest.mock import patch
import zipfile

import module_proxy
import native_payload as payload
from test_module_proxy import fixture as module_fixture


@contextmanager
def fixture(target="linux-amd64"):
    with module_fixture() as (root, plan, source, _):
        commands = ["tesl", "tesl-lsp", "tesl-dap", "tesl-mcp", "tesl-debug-inspect", "tesl-debug-attach"]
        suffix = ".exe" if target.startswith("windows-") else ""
        paths = {name: "bin/" + name + suffix for name in commands}
        paths.update({name: "libexec/tesl/postgresql/bin/" + name + suffix for name in payload.PG_COMMANDS})
        paths.update({"compiler": "libexec/tesl/tesl-compiler" + suffix, "go": "libexec/tesl/go/bin/go" + suffix,
                      **{name: "share/tesl/" + name for name in payload.DIRECTORIES}})
        plan.update(commands=commands, candidates=[{"target": target, "baseline": "fixture"}], sourceDateEpoch=12345,
                    sources={"go": {"version": "1.26.6"}, "postgresql": {"version": "17.10"}})
        manifest = {"version": 1, "target": target, "toolchain_version": plan["toolchainVersion"],
                    "source_revision": plan["sourceRevision"],
                    "components": {name: {"path": path, "version": "1.26.6" if name == "go" else
                                            "17.10" if name in payload.PG_COMMANDS else plan["toolchainVersion"]}
                                   for name, path in paths.items()}}
        extension = ".zip" if suffix else ".tar.gz"
        plan["payloads"] = {target: {"manifest": manifest,
                                    "archiveName": f"tesl-{plan['toolchainVersion']}-{target}{extension}"}}
        inputs = root / "inputs"

        def write(name, data="fixture\n", executable=False):
            file = root / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(data, encoding="utf-8")
            file.chmod(0o755 if executable else 0o644)

        for name in commands:
            write("inputs/frontends/" + name + suffix, executable=True)
        for name in payload.PG_COMMANDS:
            write("inputs/postgres/bin/" + name + suffix, executable=True)
        write("inputs/compiler", executable=True)
        write("inputs/go/bin/go" + suffix, executable=True)
        write("inputs/go/VERSION", "go1.26.6\n")
        for name in ("inputs/go/LICENSE", "inputs/postgres/COPYRIGHT", "inputs/OCaml-LICENSE", "LICENSE",
                     "README.md", "INSTALL.md", "LANGUAGE-SPEC.md", "tesl/stdlib.tesl", "templates/api/app.tesl", "manual/index.md"):
            write(name)
        for name, directory in (("go", "go"), ("postgresql", "postgres")):
            write(f"inputs/{directory}/native-build.json", json.dumps({"version": 1, "component": name,
                  "source": plan["sources"][name], "target": target}))
        bundle = root / "modules"
        module_proxy.build(plan, root, bundle, source.__getitem__)
        arguments = [plan, root, target, inputs / "compiler", inputs / "frontends", inputs / "go",
                     inputs / "postgres", bundle, inputs / "OCaml-LICENSE", root / "payload å"]
        yield arguments


def assemble(arguments):
    with patch.object(payload, "audit", return_value={"version": 1, "test_only": True}) as audit:
        payload.assemble(*arguments)
        audit.assert_called_once()
    return arguments[-1]


class NativePayloadTest(unittest.TestCase):
    def test_compiler_runtime_accepts_only_exact_recorded_dll_bytes(self):
        with fixture("windows-amd64") as args:
            plan, root, _, compiler = args[:4]
            plan["windowsRuntimeLicense"] = {"hash": "pinned-license"}
            source = root / "runtime-dlls"
            source.mkdir()
            dll = source / "vcruntime140.dll"
            dll.write_bytes(b"recorded Microsoft runtime")
            evidence = {"version": 1, "component": "compiler-runtime", "target": "windows-amd64",
                        "compiler_sha256": payload.file_hash(compiler), "license": plan["windowsRuntimeLicense"],
                        "files": {dll.name: {"sha256": payload.file_hash(dll), "authenticode": {"status": "Valid"}}}}
            metadata = source / "native-build.json"
            metadata.write_text(json.dumps(evidence))
            destination = root / "runtime-output"
            dll.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "checksum"):
                payload.copy_compiler_runtime(plan, compiler, source, destination)
            self.assertFalse(destination.exists())
            dll.write_bytes(b"recorded Microsoft runtime")
            (source / "extra.dll").write_bytes(b"unrecorded")
            with self.assertRaisesRegex(ValueError, "inventory"):
                payload.copy_compiler_runtime(plan, compiler, source, destination)
            (source / "extra.dll").unlink()
            self.assertEqual(payload.copy_compiler_runtime(plan, compiler, source, destination), evidence)
            self.assertEqual((destination / dll.name).read_bytes(), dll.read_bytes())
            compiler.write_text("different compiler")
            with self.assertRaisesRegex(ValueError, "metadata differs"):
                payload.copy_compiler_runtime(plan, compiler, source, root / "other-runtime")

    def test_complete_payload_and_licenses_match_manifest(self):
        with fixture() as args:
            root = assemble(args)
            plan, _, target = args[:3]
            manifest = json.loads((root / "share/tesl/toolchain.json").read_text())
            self.assertEqual(manifest, plan["payloads"][target]["manifest"])
            for item in manifest["components"].values():
                self.assertTrue((root / item["path"]).exists())
            for license in ("Go-LICENSE", "Tesl-LICENSE", "OCaml-LICENSE", "PostgreSQL-COPYRIGHT"):
                self.assertEqual((root / "share/tesl/licenses" / license).read_text(), "fixture\n")
            self.assertEqual((root / "bin/tesl").stat().st_mode & 0o777, 0o755)

    def test_archive_bytes_ignore_install_path_and_mtimes(self):
        for target in ("linux-amd64", "darwin-arm64", "windows-amd64"):
            with self.subTest(target=target), fixture(target) as args:
                root = assemble(args)
                plan = args[0]
                name = plan["payloads"][target]["archiveName"]
                first, second = args[1] / "one" / name, args[1] / "two" / name
                digest = payload.pack(plan, target, root, first)
                for path in root.rglob("*"):
                    os.utime(path, (1750000000, 1750000000))
                self.assertEqual(payload.pack(plan, target, root, second), digest)
                self.assertEqual(first.read_bytes(), second.read_bytes())
                prefix = name.removesuffix(".tar.gz").removesuffix(".zip")
                if name.endswith(".zip"):
                    with zipfile.ZipFile(first) as archive:
                        self.assertIn(prefix + "/bin/tesl.exe", archive.namelist())
                else:
                    with tarfile.open(first) as archive:
                        self.assertIn(prefix + "/bin/tesl", archive.getnames())
                        for item in archive:
                            self.assertEqual((item.uid, item.gid, item.mtime), (0, 0, 12345))

    def test_missing_required_input_never_leaves_partial_payload(self):
        for missing in ("inputs/frontends/tesl", "inputs/compiler", "inputs/go/LICENSE", "inputs/OCaml-LICENSE", "inputs/postgres/bin/psql"):
            with self.subTest(missing=missing), fixture() as args:
                (args[1] / missing).unlink()
                with self.assertRaises((ValueError, OSError)):
                    assemble(args)
                self.assertFalse(args[-1].exists())
                self.assertEqual(list(args[1].glob(".tesl-payload-*")), [])

    def test_wrong_component_build_identity_is_rejected(self):
        for component in ("go", "postgres"):
            for key in ("source", "target", "component", "version"):
                with self.subTest(component=component, key=key), fixture() as args:
                    path = args[1] / "inputs" / component / "native-build.json"
                    metadata = json.loads(path.read_text())
                    metadata[key] = "wrong"
                    path.write_text(json.dumps(metadata))
                    with self.assertRaisesRegex(ValueError, "build metadata"):
                        assemble(args)

    def test_empty_or_wrong_sdk_version_is_rejected(self):
        for version in ("", "go1.0.0\n"):
            with self.subTest(version=version), fixture() as args:
                (args[5] / "VERSION").write_text(version)
                with self.assertRaisesRegex(ValueError, "SDK version"):
                    assemble(args)

    def test_existing_payload_is_preserved(self):
        with fixture() as args:
            args[-1].mkdir()
            (args[-1] / "user").write_text("preserve")
            with self.assertRaises(FileExistsError):
                assemble(args)
            self.assertEqual((args[-1] / "user").read_text(), "preserve")

    def test_bad_contract_paths_identity_and_incomplete_components(self):
        for kind in ("traversal", "nested", "duplicate", "identity", "missing", "optional", "archive", "version", "sdk-prefix", "pg-prefix", "command"):
            with self.subTest(kind=kind), fixture() as args:
                plan = args[0]
                contract = plan["payloads"][args[2]]
                components = contract["manifest"]["components"]
                if kind == "traversal":
                    components["stdlib"]["path"] = "../outside"
                elif kind == "nested":
                    components["stdlib"]["path"] = "share/tesl/doc/stdlib"
                elif kind == "duplicate":
                    components["stdlib"]["path"] = components["doc"]["path"]
                elif kind == "identity":
                    contract["manifest"]["source_revision"] = "different"
                elif kind == "missing":
                    del components["psql"]
                elif kind == "optional":
                    components["psql"]["optional"] = True
                elif kind == "version":
                    components["go"]["version"] = "1.0.0"
                elif kind == "sdk-prefix":
                    components["go"]["path"] = "go"
                elif kind == "pg-prefix":
                    components["psql"]["path"] = "outside/bin/psql"
                elif kind == "command":
                    plan["commands"].append("../outside")
                else:
                    contract["archiveName"] = "../out.tar.gz"
                with self.assertRaises(ValueError):
                    assemble(args)

    def test_failed_binary_audit_is_not_packaged(self):
        with fixture() as args, patch.object(payload, "audit", side_effect=ValueError("GLIBC baseline")):
            with self.assertRaisesRegex(ValueError, "GLIBC baseline"):
                payload.assemble(*args)
            self.assertFalse(args[-1].exists())

    def test_changed_payload_and_wrong_plan_fail_before_archive_output(self):
        for change in ("file", "mode", "directory-mode", "new-directory", "identity"):
            with self.subTest(change=change), fixture() as args:
                root = assemble(args)
                plan = copy.deepcopy(args[0])
                if change == "file":
                    (root / "bin/tesl").write_bytes(b"changed")
                elif change == "mode":
                    (root / "bin/tesl").chmod(0o644)
                elif change == "directory-mode":
                    (root / "bin").chmod(0o777)
                elif change == "new-directory":
                    (root / "unlisted").mkdir()
                else:
                    plan["payloads"][args[2]]["manifest"]["components"]["go"]["version"] = "wrong"
                archive = args[1] / plan["payloads"][args[2]]["archiveName"]
                with self.assertRaises(ValueError):
                    payload.pack(plan, args[2], root, archive)
                self.assertFalse(archive.exists())

    def test_escaping_input_symlinks_rejected(self):
        with fixture() as args:
            (args[5] / "escape").symlink_to(args[1] / "LICENSE")
            with self.assertRaisesRegex(ValueError, "symlink"):
                assemble(args)


if __name__ == "__main__":
    unittest.main()

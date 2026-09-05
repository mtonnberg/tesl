"""Payload audits reject host dependencies before an archive can be published."""

import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import payload_audit as audit


def elf(machine=62, file_type=2):
    data = bytearray(64)
    data[:6] = b"\x7fELF\x02\x01"
    struct.pack_into("<HH", data, 16, file_type, machine)
    return bytes(data)


def macho(cpu=0x1000007, file_type=2):
    data = bytearray(32)
    data[:4] = b"\xcf\xfa\xed\xfe"
    struct.pack_into("<III", data, 4, cpu, 0, file_type)
    return bytes(data)


def elf_output(needed=("libc.so.6",), version="2.35", rpath=None, loader="/lib64/ld-linux-x86-64.so.2"):
    value = "  LOAD 0x0 0x0\n"
    if loader:
        value += f" [Requesting program interpreter: {loader}]\n"
    for name in needed:
        value += f" 0x1 (NEEDED) Shared library: [{name}]\n"
    if version:
        value += f" Name: GLIBC_{version} Flags: none Version: 2\n"
    if rpath is not None:
        value += f" 0x1 (RUNPATH) Library runpath: [{rpath}]\n"
    return value


def macho_output(dependencies=("/usr/lib/libSystem.B.dylib",), minimum="13.0", rpaths=(), identity=None, platform="1"):
    commands = [f" cmd LC_BUILD_VERSION\n platform {platform}\n minos {minimum}\n"]
    commands.extend(f" cmd LC_LOAD_DYLIB\n name {name} (offset 24)\n" for name in dependencies)
    commands.extend(f" cmd LC_RPATH\n path {name} (offset 12)\n" for name in rpaths)
    if identity:
        commands.append(f" cmd LC_ID_DYLIB\n name {identity} (offset 24)\n")
    return "test:\n" + "".join(f"Load command {index}\n{value}" for index, value in enumerate(commands))


class PayloadAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tesl payload å ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.binary = self.write("bin/tool", elf())

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o755)
        return path

    def plan(self, target="linux-amd64"):
        return {"commands": ["tesl"],
                "candidates": [{"target": target, "baseline": "glibc 2.35" if target.startswith("linux-") else "macOS 13"}],
                "payloads": {target: {"manifest": {"components": {
                    name: {"path": "bin/tool"} for name in audit.EXECUTABLE_COMPONENTS | {"tesl"}
                }}}}}

    def windows_plan(self):
        from test_pe_audit import pe_image
        components = {"tesl": {"path": "bin/tesl.exe"},
                      "compiler": {"path": "libexec/tesl/tesl-compiler.exe"},
                      "go": {"path": "libexec/tesl/go/bin/go.exe"}}
        for name in {"postgres", "initdb", "pg_ctl", "createdb", "psql"}:
            components[name] = {"path": "libexec/tesl/postgresql/bin/" + name + ".exe"}
        for value in components.values():
            self.write(value["path"], pe_image(imports=["kernel32.dll"]))
        return {"commands": ["tesl"], "candidates": [{"target": "windows-amd64", "baseline": "Windows 11"}],
                "payloads": {"windows-amd64": {"manifest": {"components": components}}}}

    def test_windows_audits_tools_modules_and_transitive_dll_imports(self):
        from test_pe_audit import pe_image
        plan = self.windows_plan()
        self.write("libexec/tesl/go/pkg/tool/windows_amd64/compile.exe", pe_image(imports=["kernel32.dll"]))
        library = self.write("libexec/tesl/postgresql/bin/libpq.dll", pe_image(imports=["ucrtbase.dll"], dll=True))
        self.write("libexec/tesl/postgresql/bin/psql.exe", pe_image(imports=["libpq.dll"]))
        self.write("libexec/tesl/postgresql/lib/plpgsql.dll", pe_image(imports=["postgres.exe"], dll=True))
        result = audit.audit(self.root, plan, "windows-amd64")
        self.assertEqual(result["baseline"], "Windows 11")
        self.assertTrue(all(item["format"] == "PE" for item in result["binaries"]))
        self.assertIn("libexec/tesl/go/pkg/tool/windows_amd64/compile.exe", [item["path"] for item in result["binaries"]])
        library.write_bytes(pe_image(delayed=["VCRUNTIME140.dll"], dll=True))
        with self.assertRaisesRegex(ValueError, "unbundled Windows"):
            audit.audit(self.root, plan, "windows-amd64")

    def test_windows_manifest_rejects_dll_in_place_of_executable_and_other_baseline(self):
        from test_pe_audit import pe_image
        plan = self.windows_plan()
        self.write("bin/tesl.exe", pe_image(dll=True))
        with self.assertRaisesRegex(ValueError, "not an executable"):
            audit.audit(self.root, plan, "windows-amd64")
        plan["candidates"][0]["baseline"] = "Windows latest"
        with self.assertRaisesRegex(ValueError, "unsupported Windows baseline"):
            audit.audit(self.root, plan, "windows-amd64")

    def test_linux_baseline_and_static_sdk_are_accepted(self):
        self.write("pkg/tool/linux_amd64/compile", elf())
        def inspect(args):
            return elf_output() if args[-1].endswith("/tool") else elf_output(needed=(), version=None, loader=None)
        with patch.object(audit, "_inspect", side_effect=inspect):
            evidence = audit.audit(self.root, self.plan(), "linux-amd64")
        self.assertEqual([item["path"] for item in evidence["binaries"]], ["bin/tool", "pkg/tool/linux_amd64/compile"])
        self.assertEqual(evidence["baseline"], "glibc 2.35")
        json.dumps(evidence)

    def test_linux_bundled_dependency_is_audited_recursively(self):
        self.write("lib/libpq.so.5", elf(file_type=3))
        def inspect(args):
            return (elf_output(needed=("libpq.so.5",), rpath="$ORIGIN/../lib") if args[-1].endswith("/tool")
                    else elf_output(loader=None))
        with patch.object(audit, "_inspect", side_effect=inspect):
            result = audit.audit(self.root, self.plan(), "linux-amd64")
        self.assertEqual(len(result["binaries"]), 2)
        with patch.object(audit, "_inspect", side_effect=lambda args: inspect(args).replace("GLIBC_2.35", "GLIBC_2.38")):
            with self.assertRaisesRegex(ValueError, "newer than 2.35"):
                audit.audit(self.root, self.plan(), "linux-amd64")

    def test_linux_loader_needed_entry_must_match_architecture(self):
        for target, loader in audit.ELF_LOADERS.items():
            wrong = next(value for key, value in audit.ELF_LOADERS.items() if key != target)
            with self.subTest(target=target), patch.object(audit, "_inspect", return_value=elf_output(needed=(Path(loader).name,), loader=loader)):
                audit._elf(self.root, self.binary, target, "2.35")
            with self.subTest(target=target, wrong=wrong), patch.object(audit, "_inspect", return_value=elf_output(needed=(Path(wrong).name,), loader=loader)):
                with self.assertRaisesRegex(ValueError, "wrong-architecture"):
                    audit._elf(self.root, self.binary, target, "2.35")

    def test_linux_rejects_undeclared_and_nonbaseline_dependencies(self):
        cases = [
            elf_output(version="2.38"), elf_output(version="PRIVATE"), elf_output(version=None),
            elf_output(needed=("libssl.so.3",)), elf_output(needed=("/usr/lib/libc.so.6",)),
            elf_output(loader="/nix/store/fake/lib/ld-linux.so"),
            elf_output(loader="/lib/ld-linux-aarch64.so.1"), elf_output(loader=None),
            elf_output(rpath="/usr/local/lib"), elf_output(rpath="$ORIGIN:"),
            elf_output(rpath="$ORIGIN/../../outside"), elf_output(rpath="$LIB"),
            elf_output() + " (AUDIT) Audit library: [hidden.so]\n", "",
        ]
        for output in cases:
            with self.subTest(output=output), patch.object(audit, "_inspect", return_value=output):
                with self.assertRaises(ValueError):
                    audit.audit(self.root, self.plan(), "linux-amd64")

    def test_linux_arm64_requires_its_own_architecture_and_loader(self):
        self.binary.write_bytes(elf(machine=183))
        with patch.object(audit, "_inspect", return_value=elf_output(loader="/lib/ld-linux-aarch64.so.1")):
            audit.audit(self.root, self.plan("linux-arm64"), "linux-arm64")
            with self.assertRaisesRegex(ValueError, "architecture"):
                audit.audit(self.root, self.plan(), "linux-amd64")

    def test_linux_cannot_shadow_baseline_libraries_in_unscanned_resource_paths(self):
        self.write("share/dependencies/libc.so.6", elf(file_type=3))
        with patch.object(audit, "_inspect", return_value=elf_output(rpath="$ORIGIN/../share/dependencies")):
            with self.assertRaisesRegex(ValueError, "shadows an OS baseline"):
                audit.audit(self.root, self.plan(), "linux-amd64")

    def test_magic_architecture_nix_references_and_executable_permissions(self):
        for data in (b"#!/bin/sh\n", elf(machine=183), elf(file_type=1), elf() + b"/nix/store/secret", macho(), b"\x7fELF"):
            with self.subTest(data=data):
                self.binary.write_bytes(data)
                with self.assertRaises(ValueError):
                    audit.audit(self.root, self.plan(), "linux-amd64")
        self.binary.write_bytes(elf())
        self.binary.chmod(0o644)
        if os.name != "nt":
            with self.assertRaisesRegex(ValueError, "not executable"):
                audit.audit(self.root, self.plan(), "linux-amd64")

    def test_sibling_and_sdk_tools_cannot_hide_foreign_binaries(self):
        for name in ("bin/other", "pkg/tool/linux_amd64/link", "lib/plugin.so"):
            with self.subTest(name=name), patch.object(audit, "_inspect", return_value=elf_output()):
                path = self.write(name, macho())
                try:
                    with self.assertRaisesRegex(ValueError, "ELF64"):
                        audit.audit(self.root, self.plan(), "linux-amd64")
                finally:
                    path.unlink()
        # SDK testdata is not an executable tool and contains foreign formats.
        self.write("src/debug/elf/testdata/foreign", macho())
        with patch.object(audit, "_inspect", return_value=elf_output()):
            audit.audit(self.root, self.plan(), "linux-amd64")

    def test_missing_unsafe_and_unsupported_plan_fail_before_inspection(self):
        for name in ("../tool", "/tool", "bin//tool", "C:/tool", "bin\\tool", "missing"):
            plan = self.plan()
            plan["payloads"]["linux-amd64"]["manifest"]["components"]["compiler"]["path"] = name
            with self.subTest(name=name), patch.object(audit, "_inspect", return_value=elf_output()):
                with self.assertRaises(ValueError):
                    audit.audit(self.root, plan, "linux-amd64")
        with self.assertRaisesRegex(ValueError, "not implemented"):
            audit.audit(self.root, self.plan(), "windows-arm64")
        with self.assertRaisesRegex(ValueError, "metadata"):
            audit.audit(self.root, {}, "linux-amd64")

    @unittest.skipIf(os.name == "nt", "Windows symlink creation needs privileges")
    def test_symlink_escape_fails_even_if_library_exists(self):
        (self.root / "lib").mkdir()
        (self.root / "lib/host.so").symlink_to("/bin/true")
        with patch.object(audit, "_inspect", return_value=elf_output(needed=("host.so",), rpath="$ORIGIN/../lib")):
            with self.assertRaisesRegex(ValueError, "escapes payload"):
                audit.audit(self.root, self.plan(), "linux-amd64")

    def test_macos_baseline_and_local_library_closure(self):
        self.binary.write_bytes(macho())
        self.write("lib/libpq.dylib", macho(file_type=6))
        def inspect(args):
            return (macho_output(dependencies=("@rpath/libpq.dylib",), rpaths=("@loader_path/../lib",))
                    if args[-1].endswith("/tool") else macho_output(identity="@rpath/libpq.dylib"))
        with patch.object(audit, "_inspect", side_effect=inspect):
            result = audit.audit(self.root, self.plan("darwin-amd64"), "darwin-amd64")
        self.assertEqual(len(result["binaries"]), 2)

    def test_macos_rejects_newer_system_and_external_libraries(self):
        self.binary.write_bytes(macho())
        cases = [macho_output(minimum="15.0"), macho_output(platform="2"), "",
                 macho_output(dependencies=("/opt/homebrew/lib/libpq.dylib",)),
                 macho_output(dependencies=("@rpath/libpq.dylib",)),
                 macho_output(dependencies=("@loader_path/../../host.dylib",)),
                 macho_output(rpaths=("/opt/homebrew/lib",)),
                 macho_output(dependencies=("/usr/lib/../../opt/external.dylib",)),
                 macho_output(identity="/build/libpq.dylib"),
                 macho_output() + "Load command 99\n cmd LC_DYLD_ENVIRONMENT\n"]
        for output in cases:
            with self.subTest(output=output), patch.object(audit, "_inspect", return_value=output):
                with self.assertRaises(ValueError):
                    audit.audit(self.root, self.plan("darwin-amd64"), "darwin-amd64")

    def test_macos_arm64_and_old_deployment_load_command(self):
        self.binary.write_bytes(macho(cpu=0x100000c))
        output = "tool:\nLoad command 0\n cmd LC_VERSION_MIN_MACOSX\n version 12.0\n"
        with patch.object(audit, "_inspect", return_value=output):
            audit.audit(self.root, self.plan("darwin-arm64"), "darwin-arm64")
            with self.assertRaisesRegex(ValueError, "architecture"):
                audit.audit(self.root, self.plan("darwin-amd64"), "darwin-amd64")

    def test_inspection_failure_is_an_error_and_locale_is_stable(self):
        for error in (FileNotFoundError("readelf"), subprocess.CalledProcessError(1, ["readelf"])):
            with patch.object(audit.subprocess, "run", side_effect=error):
                with self.assertRaisesRegex(ValueError, "inspection failed"):
                    audit._inspect(["readelf", "binary å"])
        with patch.object(audit.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="ok")) as run:
            self.assertEqual(audit._inspect(["readelf", "binary å"]), "ok")
            self.assertEqual(run.call_args.kwargs["env"]["LC_ALL"], "C")

    @unittest.skipUnless(shutil.which("readelf") and Path("/bin/true").is_file(), "requires a native Linux ELF")
    def test_real_readelf_audits_host_binary_and_rejects_too_old_baseline(self):
        data = Path("/bin/true").read_bytes()
        if data[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<H", data, 18)[0] != 62:
            self.skipTest("integration fixture is not Linux amd64")
        self.binary.write_bytes(data)
        plan = self.plan()
        # The test host may be newer than the release baseline; this is a parser
        # integration check, not evidence that the host binary is distributable.
        plan["candidates"][0]["baseline"] = "glibc 99.0"
        evidence = audit.audit(self.root, plan, "linux-amd64")
        self.assertIn("libc.so.6", evidence["binaries"][0]["needed"])
        plan["candidates"][0]["baseline"] = "glibc 2.2"
        with self.assertRaisesRegex(ValueError, "newer than 2.2"):
            audit.audit(self.root, plan, "linux-amd64")


if __name__ == "__main__":
    unittest.main()

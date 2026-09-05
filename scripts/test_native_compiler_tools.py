"""Provenance and failure boundaries for the temporary compiler toolchain."""

import base64
from contextlib import redirect_stderr
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import native_compiler_tools as compiler
from test_pe_audit import pe_image


class CompilerToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tesl-compiler-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / "installed"
        self.plan = {"version": 1, "sourceDateEpoch": 123,
                     "candidates": [{"target": "linux-amd64"}, {"target": "darwin-arm64", "baseline": "macOS 13"}],
                     "sources": {}}
        self.archives = []
        for name, version, files in (
                ("ocaml", "5.4.1", {"configure": "build", "VERSION": "5.4.1\n", "LICENSE": "notice", "LICENSES/exception": "exception"}),
                ("dune", "3.21.1", {"boot/bootstrap.ml": "bootstrap"})):
            archive = self.root / (name + ".tar")
            with tarfile.open(archive, "w") as stream:
                for relative, content in files.items():
                    info = tarfile.TarInfo(name + "/" + relative)
                    info.size = len(content)
                    info.mode = 0o755 if relative == "configure" else 0o644
                    stream.addfile(info, io.BytesIO(content.encode()))
            digest = base64.b64encode(hashlib.sha256(archive.read_bytes()).digest()).decode()
            self.plan["sources"][name] = {"version": version, "hash": "sha256-" + digest,
                                         "hashAlgorithm": "sha256", "hashMode": "flat", "stripRoot": False}
            self.archives.append(archive)
        host = patch.object(compiler, "host_target", return_value="linux-amd64")
        host.start()
        self.addCleanup(host.stop)
        self.calls = []

    def fake_build(self, arguments, directory, environment, capture=False):
        args = list(map(str, arguments))
        self.calls.append(args)
        if args == ["make", "install"]:
            (self.output / "bin").mkdir()
        if "boot/bootstrap.ml" in args:
            (directory / "_boot").mkdir()
            (directory / "_boot/dune.exe").write_text("built dune")
            (directory / "dune.exe").write_text("source wrapper")
        if capture:
            return "3.21.1" if args[-1] == "--version" else "5.4.1"

    def build(self):
        return compiler.build(self.plan, "linux-amd64", *self.archives, self.output, jobs=2)

    def test_captured_build_failure_preserves_tool_diagnostics(self):
        diagnostics = io.StringIO()
        child = "import sys; print('tool stdout'); print('module failed to load', file=sys.stderr); sys.exit(7)"
        with redirect_stderr(diagnostics), self.assertRaises(subprocess.CalledProcessError) as failure:
            compiler.run([sys.executable, "-c", child], self.root, dict(os.environ), capture=True)
        self.assertEqual(failure.exception.returncode, 7)
        self.assertIn("tool stdout", diagnostics.getvalue())
        self.assertIn("module failed to load", diagnostics.getvalue())

    def test_verified_sources_and_license_tree_are_recorded(self):
        with patch.object(compiler, "run", side_effect=self.fake_build):
            result = self.build()
        self.assertEqual((result / "licenses/LICENSES/exception").read_text(), "exception")
        self.assertEqual((result / "bin/dune").read_text(), "built dune")
        evidence = json.loads((result / "native-build.json").read_text())
        self.assertEqual(evidence["sources"], self.plan["sources"])
        self.assertTrue(evidence["source_hashes_verified"])
        self.assertFalse(evidence["ocaml_compression"])
        self.assertIn("--without-zstd", self.calls[0])
        self.assertFalse(list(self.root.glob(".tesl-compiler-tools-*")))

    def test_installed_dune_is_checked_after_all_sources_are_removed(self):
        def run(arguments, directory, environment, capture=False):
            if list(map(str, arguments)) == [str(self.output / "bin/dune"), "--version"]:
                self.assertEqual(directory, self.output.parent)
                self.assertFalse(list(self.root.glob(".tesl-compiler-tools-*")))
                self.assertEqual((self.output / "bin/dune").read_text(), "built dune")
                raise subprocess.CalledProcessError(1, "installed-dune")
            return self.fake_build(arguments, directory, environment, capture)
        with patch.object(compiler, "run", side_effect=run):
            with self.assertRaises(subprocess.CalledProcessError):
                self.build()
        self.assertFalse(self.output.exists())

    def test_both_archives_verify_before_any_build_script_runs(self):
        self.archives[1].write_bytes(b"tampered")
        with patch.object(compiler, "run") as run:
            with self.assertRaises(ValueError):
                self.build()
        run.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_unexpected_source_version_never_executes_configure(self):
        self.plan["sources"]["ocaml"]["version"] = "5.4.2"
        with patch.object(compiler, "run") as run:
            with self.assertRaisesRegex(ValueError, "source version"):
                self.build()
        run.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_failed_build_removes_only_its_partial_installation(self):
        preserved = self.root / "unrelated"
        preserved.write_text("keep")
        with patch.object(compiler, "run", side_effect=subprocess.CalledProcessError(1, "make")):
            with self.assertRaises(subprocess.CalledProcessError):
                self.build()
        self.assertFalse(self.output.exists())
        self.assertEqual(preserved.read_text(), "keep")
        self.assertFalse(list(self.root.glob(".tesl-compiler-tools-*")))

    def test_existing_installation_is_preserved(self):
        self.output.mkdir()
        (self.output / "keep").write_text("keep")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.build()
        self.assertEqual((self.output / "keep").read_text(), "keep")

    def test_reported_dune_version_must_match_the_pin(self):
        self.plan["sources"]["dune"]["version"] = "3.22.0"
        with patch.object(compiler, "run", side_effect=self.fake_build):
            with self.assertRaisesRegex(ValueError, "Dune version"):
                self.build()
        self.assertFalse(self.output.exists())

    def test_build_environment_excludes_host_ocaml_and_linker_injection(self):
        original = {"PATH": "system", "OCAMLPATH": "other", "OCAMLLIB": "other", "OPAM_SWITCH_PREFIX": "other",
                    "LD_PRELOAD": "injected", "CAML_LD_LIBRARY_PATH": "other", "CFLAGS": "-march=native",
                    "NIX_LDFLAGS": "other", "DUNE_PROFILE": "other", "MACOSX_DEPLOYMENT_TARGET": "99"}
        env = compiler.build_environment(original, self.plan, "darwin-arm64", self.output)
        for key in ("OCAMLPATH", "OPAM_SWITCH_PREFIX", "LD_PRELOAD", "CAML_LD_LIBRARY_PATH", "NIX_LDFLAGS", "DUNE_PROFILE"):
            self.assertNotIn(key, env)
        self.assertEqual(env["OCAMLLIB"], str(self.output / "lib/ocaml"))
        self.assertEqual(env["MACOSX_DEPLOYMENT_TARGET"], "13")
        self.assertEqual(env["CFLAGS"], "-O2")
        self.assertEqual(env["PATH"], str(self.output / "bin") + os.pathsep + "system")

    def windows_inputs(self):
        self.plan["candidates"].append({"target": "windows-amd64"})
        self.plan["windowsCompilerSources"] = {}
        archives = {}
        for name, sentinel in compiler.WINDOWS_SOURCES.items():
            archive = self.root / (name + ".tar")
            with tarfile.open(archive, "w") as stream:
                for relative in (sentinel, "LICENSE"):
                    content = (name + " source notice").encode()
                    info = tarfile.TarInfo(name + "/" + relative)
                    info.size = len(content)
                    stream.addfile(info, io.BytesIO(content))
            digest = base64.b64encode(hashlib.sha256(archive.read_bytes()).digest()).decode()
            self.plan["windowsCompilerSources"][name] = {"hash": "sha256-" + digest,
                                                        "hashAlgorithm": "sha256", "hashMode": "flat", "stripRoot": False}
            archives[name] = archive
        bash = self.root / "Cygwin tools/bin/bash.exe"
        bash.parent.mkdir(parents=True)
        bash.touch()
        bash.with_name("cygpath.exe").touch()
        return {"windows_archives": archives, "cygwin_bash": bash}

    def test_windows_source_build_records_all_pins_and_licenses(self):
        inputs = self.windows_inputs()
        def windows(ocaml, sources, output, bash, environment, jobs):
            self.assertEqual(set(sources), set(compiler.WINDOWS_SOURCES))
            self.assertNotIn("OCAMLLIB", environment)
            (output / "bin").mkdir()
            return ["configure", "--host=x86_64-pc-windows"], "CYGWIN_NT-10.0"
        def run(arguments, directory, environment, capture=False):
            if "-config-var" in arguments:
                return {"architecture": "amd64", "os_type": "Win32", "ccomp_type": "msvc"}[arguments[-1]]
            return self.fake_build(arguments, directory, environment, capture)
        with patch.object(compiler, "host_target", return_value="windows-amd64"), \
                patch.object(compiler, "build_windows", side_effect=windows), patch.object(compiler, "run", side_effect=run):
            result = compiler.build(self.plan, "windows-amd64", *self.archives, self.output, **inputs)
        evidence = json.loads((result / "native-build.json").read_text())
        self.assertEqual(evidence["windows_compiler_sources"], self.plan["windowsCompilerSources"])
        self.assertEqual(evidence["windows_toolchain"], "msvc")
        self.assertFalse(evidence["cygwin_runtime"])
        self.assertEqual((result / "bin/dune.exe").read_text(), "built dune")
        for name in compiler.WINDOWS_SOURCES:
            self.assertEqual((result / "licenses" / name / "LICENSE").read_text(), name + " source notice")

    def test_windows_authenticates_the_last_dependency_before_running_any_script(self):
        inputs = self.windows_inputs()
        inputs["windows_archives"]["winpthreads"].write_bytes(b"tampered")
        with patch.object(compiler, "host_target", return_value="windows-amd64"), patch.object(compiler, "run") as run:
            with self.assertRaises(ValueError):
                compiler.build(self.plan, "windows-amd64", *self.archives, self.output, **inputs)
        run.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_windows_requires_all_extra_sources_and_explicit_cygwin(self):
        inputs = self.windows_inputs()
        with patch.object(compiler, "host_target", return_value="windows-amd64"):
            for partial in ({}, {**inputs, "windows_archives": {}}, {**inputs, "cygwin_bash": None}):
                with self.subTest(partial=partial), self.assertRaises(ValueError):
                    compiler.build(self.plan, "windows-amd64", *self.archives, self.output, **partial)

    def test_windows_retains_selected_msvc_libraries_but_removes_injection_flags(self):
        tool = self.root / "Visual Studio/bin/cl.exe"
        tool.parent.mkdir(parents=True)
        tool.touch()
        tool.with_name("link.exe").touch()
        original = {"PATH": "Cygwin first", "INCLUDE": "SDK include", "LIB": "SDK lib", "LIBPATH": "SDK libpath",
                    "CL": "injected", "_CL_": "injected", "LINK": "injected", "BASH_ENV": "injected", "ENV": "injected"}
        with patch.object(compiler.shutil, "which", return_value=str(tool)):
            environment = compiler.build_environment(original, self.plan, "windows-amd64", self.output)
        for name in ("INCLUDE", "LIB", "LIBPATH"):
            self.assertEqual(environment[name], original[name])
        for name in ("CFLAGS", "CL", "_CL_", "LINK", "BASH_ENV", "ENV"):
            self.assertNotIn(name, environment)
        self.assertEqual(environment["CC"], "cl.exe")
        self.assertEqual(environment["PATH"].split(compiler.os.pathsep)[0], str(tool.parent))

    def test_windows_build_uses_explicit_msvc_linker_and_positional_paths(self):
        inputs = self.windows_inputs()
        tool = self.root / "Visual Studio/bin/cl.exe"
        tool.parent.mkdir(parents=True)
        tool.touch()
        tool.with_name("link.exe").touch()
        paths = ["/source with spaces", "/prefix $literal", "/flex", "/pthread", "/Visual Studio/bin"]
        with patch.object(compiler.shutil, "which", return_value=str(tool)), \
                patch.object(compiler, "cygwin_path", side_effect=paths), \
                patch.object(compiler, "run", side_effect=["CYGWIN_NT-10.0", None]) as run:
            configure, platform = compiler.build_windows(self.root, {name: self.root for name in compiler.WINDOWS_SOURCES},
                                                         self.output, inputs["cygwin_bash"], {}, 3)
        command = run.call_args_list[-1].args[0]
        self.assertEqual(command[-6:], paths + ["3"])
        self.assertIn('export PATH="$5:/usr/bin:/bin:$PATH"', command[4])
        self.assertNotIn(paths[0], command[4])
        self.assertIn("--host=x86_64-pc-windows", configure)
        self.assertIn("--without-zstd", configure)

    def test_windows_rejects_git_bash_and_missing_msvc_linker(self):
        inputs = self.windows_inputs()
        with patch.object(compiler.shutil, "which", return_value=None), self.assertRaisesRegex(ValueError, "MSVC"):
            compiler.build_windows(self.root, {}, self.output, inputs["cygwin_bash"], {}, 2)
        tool = self.root / "cl.exe"
        tool.with_name("link.exe").touch()
        with patch.object(compiler.shutil, "which", return_value=str(tool)), \
                patch.object(compiler, "run", return_value="MSYS_NT-10.0"), self.assertRaisesRegex(ValueError, "Cygwin"):
            compiler.build_windows(self.root, {}, self.output, inputs["cygwin_bash"], {}, 2)


class CompilerRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tesl compiler runtime å ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tools = self.root / "compiler tools"
        (self.tools / "licenses").mkdir(parents=True)
        self.binary = self.root / "compiler.exe"
        self.binary.write_bytes(pe_image(imports=["kernel32.dll", "VCRUNTIME140.dll", "api-ms-win-core-synch-l1-2-0.dll"]))
        self.studio = self.root / "Visual Studio"
        self.redist = self.studio / "VC/Redist/MSVC/14.44.12345"
        self.dlls = self.redist / "x64/Microsoft.VC143.CRT"
        self.dlls.mkdir(parents=True)
        (self.dlls / "vcruntime140.dll").write_bytes(pe_image(delayed=["vcruntime140_1.dll"], dll=True))
        (self.dlls / "vcruntime140_1.dll").write_bytes(pe_image(imports=["ucrtbase.dll"], dll=True))
        (self.dlls / "msvcp140.dll").write_bytes(pe_image(dll=True))
        self.environment = {"VSINSTALLDIR": str(self.studio), "VCToolsRedistDir": str(self.redist),
                            "VCToolsVersion": "14.44.12345", "WindowsSDKVersion": "10.0.26100.0",
                            "PATH": "/untrusted"}
        self.license = self.root / "license.docx"
        document = ('<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
                    '<w:body><w:p><w:r><w:t>MICROSOFT VISUAL C++ 2015 - 2022 RUNTIME</w:t></w:r></w:p></w:body></w:document>')
        with zipfile.ZipFile(self.license, "w") as archive:
            archive.writestr("word/document.xml", document)
        digest = base64.b64encode(hashlib.sha256(self.license.read_bytes()).digest()).decode()
        self.plan = {"windowsRuntimeLicense": {"hash": "sha256-" + digest, "hashMode": "flat", "hashAlgorithm": "sha256"}}
        self.identity = {"status": "Valid", "signer": "CN=Microsoft Corporation, O=Microsoft Corporation", "version": "14.44.1.0"}

    def collect(self):
        return compiler.collect_windows_runtime(self.binary, self.tools, self.plan, self.environment, self.license)

    def test_only_final_pe_dependency_closure_is_copied_with_license_and_hashes(self):
        with patch.object(compiler, "microsoft_runtime_identity", return_value=self.identity) as signature:
            output = self.collect()
        self.assertEqual({path.name for path in output.iterdir()}, {"vcruntime140.dll", "vcruntime140_1.dll", "native-build.json"})
        self.assertEqual(signature.call_count, 2)
        metadata = json.loads((output / "native-build.json").read_text())
        self.assertEqual(metadata["compiler_sha256"], hashlib.sha256(self.binary.read_bytes()).hexdigest())
        self.assertEqual(metadata["license"], self.plan["windowsRuntimeLicense"])
        for name, item in metadata["files"].items():
            self.assertEqual(item["sha256"], hashlib.sha256((output / name).read_bytes()).hexdigest())
            self.assertTrue(item["source"].startswith("VC/Redist/MSVC/14.44.12345/x64/Microsoft.VC143.CRT/"))
            self.assertEqual(item["authenticode"], self.identity)
        self.assertEqual((self.tools / "licenses/msvc-runtime/Microsoft-Visual-C-Runtime-2015-2022.docx").read_bytes(), self.license.read_bytes())
        self.assertIn("MICROSOFT VISUAL C++", (self.tools / "licenses/msvc-runtime/LICENSE.txt").read_text())

    def test_windows_environment_casing_preserves_runtime_selection_and_version_evidence(self):
        for case in (str.upper, str.lower):
            with self.subTest(case=case.__name__):
                environment = {case(key): value for key, value in self.environment.items()}
                original = dict(environment)
                tools = self.root / case.__name__
                (tools / "licenses").mkdir(parents=True)
                with patch.object(compiler, "microsoft_runtime_identity", return_value=self.identity):
                    output = compiler.collect_windows_runtime(self.binary, tools, self.plan, environment, self.license)
                metadata = json.loads((output / "native-build.json").read_text())
                self.assertEqual(metadata["msvc_version"], "14.44.12345")
                self.assertEqual(metadata["windows_sdk_version"], "10.0.26100.0")
                self.assertEqual(set(metadata["files"]), {"vcruntime140.dll", "vcruntime140_1.dll"})
                self.assertEqual(environment, original)

    def test_missing_redist_dependency_never_uses_another_directory(self):
        (self.dlls / "vcruntime140.dll").rename(self.root / "vcruntime140.dll")
        self.environment["PATH"] = str(self.root)
        with self.assertRaisesRegex(ValueError, "declared MSVC"):
            self.collect()
        self.assertFalse((self.tools / "runtime").exists())

    def test_non_redist_ownership_and_debug_directories_are_rejected(self):
        self.environment["VCToolsRedistDir"] = str(self.root)
        with self.assertRaisesRegex(ValueError, "outside"):
            self.collect()
        debug = self.redist / "debug_nonredist"
        debug.mkdir()
        self.environment["VCToolsRedistDir"] = str(debug)
        with self.assertRaisesRegex(ValueError, "one VS2022"):
            self.collect()

    def test_tampered_license_is_rejected_before_dependency_signature_execution(self):
        self.license.write_bytes(b"tampered")
        with patch.object(compiler, "microsoft_runtime_identity") as signature, self.assertRaisesRegex(ValueError, "checksum"):
            self.collect()
        signature.assert_not_called()

    def test_unsigned_runtime_is_not_published(self):
        with patch.object(compiler, "microsoft_runtime_identity", side_effect=ValueError("bad signature")), \
                self.assertRaisesRegex(ValueError, "signature"):
            self.collect()
        self.assertFalse((self.tools / "runtime").exists())
        self.assertFalse((self.tools / "licenses/msvc-runtime").exists())

    def test_signature_check_uses_literal_path_and_requires_microsoft_identity(self):
        path = self.dlls / "vcruntime140.dll"
        self.environment.update(PSMODULEPATH="PowerShell 7 modules", PSModulePath="another inherited path")
        original = dict(self.environment)
        with patch.object(compiler, "run", return_value=json.dumps(self.identity)) as run:
            self.assertEqual(compiler.microsoft_runtime_identity(path, self.environment), self.identity)
        command, _, environment, _ = run.call_args.args
        self.assertNotIn(str(path), command[-1])
        self.assertEqual(environment["TESL_MSVC_RUNTIME_FILE"], str(path))
        self.assertFalse(any(key.upper() == "PSMODULEPATH" for key in environment))
        self.assertEqual(self.environment, original)
        for changed in ({"signer": "CN=Other Vendor"}, {"status": "NotSigned"}, {"status": "HashMismatch"},
                        {"status": "UnknownError", "status_message": "certificate chain failed"}, {"version": "15.0.1.0"}):
            with self.subTest(changed=changed), \
                    patch.object(compiler, "run", return_value=json.dumps({**self.identity, **changed})), \
                    self.assertRaisesRegex(ValueError, "signature/version") as failure:
                compiler.microsoft_runtime_identity(path, self.environment)
            for value in changed.values():
                self.assertIn(value, str(failure.exception))

    def test_unexpected_private_dll_and_existing_output_are_rejected(self):
        self.binary.write_bytes(pe_image(imports=["zstd.dll"]))
        with self.assertRaisesRegex(ValueError, "declared MSVC"):
            self.collect()
        output = self.tools / "runtime"
        output.mkdir()
        (output / "keep").write_text("keep")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.collect()
        self.assertEqual((output / "keep").read_text(), "keep")

    def test_redirected_runtime_file_and_future_api_contract_are_rejected(self):
        runtime = self.dlls / "vcruntime140.dll"
        runtime.unlink()
        runtime.symlink_to(self.dlls / "vcruntime140_1.dll")
        with self.assertRaisesRegex(ValueError, "redirected"):
            self.collect()
        runtime.unlink()
        self.binary.write_bytes(pe_image(imports=["api-ms-win-core-synch-l1-99-0.dll"]))
        with self.assertRaisesRegex(ValueError, "declared MSVC"):
            self.collect()


if __name__ == "__main__":
    unittest.main()

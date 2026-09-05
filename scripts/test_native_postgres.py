"""Native PostgreSQL builds must preserve source identity and loader closure."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import native_postgres as pg


class NativePostgresTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="postgres component å ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        native_tools = tempfile.TemporaryDirectory(prefix="PostgreSQL MSVC å ")
        self.addCleanup(native_tools.cleanup)
        self.msvc = Path(native_tools.name) / "cl.exe"
        self.msvc.touch()
        self.msvc.with_name("link.exe").touch()
        self.plan = {"version": 1, "toolchainVersion": "0.3.1-dev.test", "sourceRevision": "abc",
                     "sourceDateEpoch": 42, "candidates": [{"target": "linux-amd64"},
                                                            {"target": "darwin-arm64", "baseline": "macOS 13"},
                                                            {"target": "windows-amd64"}],
                     "sources": {"postgresql": {"version": "17.10", "hash": "pinned"}}}
        patcher = patch.object(pg, "native_target", return_value="linux-amd64")
        patcher.start()
        self.addCleanup(patcher.stop)

    def install_fixture(self, prefix):
        for command in pg.COMMANDS:
            path = prefix / "bin" / command
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"\x7fELF fake unit-test binary")
        (prefix / "lib").mkdir()
        (prefix / "lib/libpq.so.5").write_bytes(b"\x7fELF fake shared library")
        (prefix / "share/timezone").mkdir(parents=True)
        for resource in ("postgres.bki", "postgresql.conf.sample"):
            (prefix / "share" / resource).write_text("resource")

    def extract_fixture(self, source, archive, destination):
        destination.mkdir()
        (destination / "configure").write_text("PACKAGE_VERSION='17.10'\n")
        (destination / "COPYRIGHT").write_text("PostgreSQL license")
        (destination / "src/backend/regex").mkdir(parents=True)
        (destination / "src/backend/regex/COPYRIGHT").write_text("Regex license")
        return destination

    def run_fixture(self, arguments, directory, environment, capture=False):
        if arguments[-1] == "install":
            stage = Path(next(item.removeprefix("DESTDIR=") for item in arguments if item.startswith("DESTDIR=")))
            self.install_fixture(stage / pg.PREFIX.lstrip("/"))
        if arguments[-1] == "--version":
            return "PostgreSQL 17.10\n"
        return None

    def test_validation_rejects_bad_plan_target_host_and_jobs_before_extraction(self):
        cases = [(dict(self.plan, version=2), "linux-amd64", 2, "release plan"),
                 (self.plan, "linux-arm64", 2, "absent"),
                 (self.plan, "windows-amd64", 2, "native host"),
                 (self.plan, "darwin-arm64", 2, "native host"),
                 (self.plan, "linux-amd64", 0, "positive integer"),
                 (self.plan, "linux-amd64", True, "positive integer"),
                 (dict(self.plan, sources={"postgresql": {"version": "17; echo bad"}}),
                  "linux-amd64", 2, "invalid PostgreSQL version")]
        for plan, target, jobs, error in cases:
            with self.subTest(target=target, jobs=jobs, error=error):
                with patch.object(pg, "extract_verified") as extract:
                    with self.assertRaisesRegex(ValueError, error):
                        pg.build(plan, target, self.root / "archive", self.root / "output", jobs)
                    extract.assert_not_called()

    def test_configure_uses_relocatable_layout_and_disables_optional_libraries(self):
        args = pg.configure_arguments(Path("source"))
        self.assertIn("--prefix=/tesl-postgresql", args)
        self.assertIn("--disable-nls", args)
        self.assertNotIn("--with-system-tzdata", " ".join(args))
        # PostgreSQL's --without-ssl is rejected by its own configure script;
        # --without-openssl is the supported way to disable the optional library.
        self.assertIn("--without-openssl", args)
        self.assertNotIn("--without-ssl", args)
        for option in ("icu", "readline", "zlib", "llvm", "gssapi", "ldap", "lz4", "zstd"):
            self.assertIn("--without-" + option, args)
        self.assertEqual(pg.make_arguments("linux-amd64"), ["rpath=-Wl,-rpath,'$$ORIGIN/../lib'"])
        self.assertEqual(pg.make_arguments("darwin-arm64"), ["rpath=-Wl,-rpath,@loader_path/../lib"])

    def test_environment_removes_injected_link_flags_and_host_library_searches(self):
        hostile = {key: "host injected" for key in ("LDFLAGS", "LIBS", "NIX_LDFLAGS", "CPPFLAGS",
                   "MAKEFLAGS", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "PKG_CONFIG_PATH", "ICU_LIBS",
                   "CPATH", "CFLAGS", "CONFIG_SITE", "MAKELEVEL", "with_ssl",
                   "DYLD_FALLBACK_LIBRARY_PATH", "LD_PRELOAD", "ac_cv_lib_ssl_SSL_new")}
        with patch.dict(os.environ, dict(hostile, PATH="native tools"), clear=True):
            environment = pg.build_environment(self.plan)
        self.assertEqual(environment["PATH"], "native tools")
        self.assertEqual(environment["CFLAGS"], "-O2")
        self.assertEqual(environment["CONFIG_SITE"], "/dev/null")
        self.assertEqual(environment["SOURCE_DATE_EPOCH"], "42")
        self.assertEqual(environment["MAKELEVEL"], "0")
        for key in set(hostile) - {"CFLAGS", "CONFIG_SITE", "MAKELEVEL"}:
            self.assertNotIn(key, environment)

    def test_macos_deployment_target_comes_from_plan_and_requires_valid_baseline(self):
        with patch.dict(os.environ, {"MACOSX_DEPLOYMENT_TARGET": "15.2"}):
            environment = pg.build_environment(self.plan, "darwin-arm64")
        self.assertEqual(environment["MACOSX_DEPLOYMENT_TARGET"], "13")
        self.plan["candidates"][1]["baseline"] = "latest"
        with self.assertRaisesRegex(ValueError, "macOS baseline"):
            pg.build_environment(self.plan, "darwin-arm64")

    def test_build_stages_resources_and_license_and_preserves_source_identity(self):
        with patch.object(pg, "extract_verified", side_effect=self.extract_fixture) as extract, \
                patch.object(pg, "run", side_effect=self.run_fixture) as run, \
                patch.object(pg, "audit", return_value={"bin/postgres": ["libc.so.6"]}):
            output = pg.build(self.plan, "linux-amd64", self.root / "archive", self.root / "output", 3)
        extract.assert_called_once()
        self.assertEqual(extract.call_args.args[0], self.plan["sources"]["postgresql"])
        pg.check_layout(output)
        self.assertEqual((output / "COPYRIGHT").read_text(), "PostgreSQL license")
        metadata = json.loads((output / "native-build.json").read_text())
        self.assertEqual(metadata["source"], self.plan["sources"]["postgresql"])
        self.assertEqual(metadata["source_revision"], "abc")
        self.assertEqual(metadata["target"], "linux-amd64")
        self.assertEqual((output / "licenses/src/backend/regex/COPYRIGHT").read_text(), "Regex license")
        self.assertEqual(metadata["licenses"], ["COPYRIGHT", "src/backend/regex/COPYRIGHT"])
        self.assertIn("ssl", metadata["disabled_features"])
        self.assertIn("share/timezone", [p.relative_to(output).as_posix() for p in output.rglob("*")])
        self.assertEqual(run.call_args_list[1].args[0][:3], ["make", "-j", "3"])
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["output"])

    def test_failed_extraction_or_build_never_publishes_partial_component(self):
        for phase in ("extract", "configure", "audit", "version"):
            with self.subTest(phase=phase):
                def run(arguments, *args, **kwargs):
                    if phase == "configure" and arguments[0].endswith("configure"):
                        raise subprocess.CalledProcessError(1, arguments)
                    if phase == "version" and arguments[-1] == "--version":
                        return "PostgreSQL 16.0"
                    return self.run_fixture(arguments, *args, **kwargs)
                extract_effect = ValueError("bad checksum") if phase == "extract" else self.extract_fixture
                with patch.object(pg, "extract_verified", side_effect=extract_effect), \
                        patch.object(pg, "run", side_effect=run), \
                        patch.object(pg, "audit", side_effect=ValueError("bad dependency") if phase == "audit" else None):
                    with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                        pg.build(self.plan, "linux-amd64", self.root / "archive", self.root / "output")
                self.assertEqual(list(self.root.iterdir()), [])

    def test_existing_output_and_source_version_mismatch_fail_before_build(self):
        output = self.root / "output"
        output.mkdir()
        with patch.object(pg, "extract_verified") as extract, self.assertRaisesRegex(ValueError, "already exists"):
            pg.build(self.plan, "linux-amd64", self.root / "archive", output)
        extract.assert_not_called()
        output.rmdir()
        self.plan["sources"]["postgresql"]["version"] = "18.0"
        with patch.object(pg, "extract_verified", side_effect=self.extract_fixture), patch.object(pg, "run") as run:
            with self.assertRaisesRegex(ValueError, "source version differs"):
                pg.build(self.plan, "linux-amd64", self.root / "archive", output)
            run.assert_not_called()

    def test_layout_requires_all_commands_resources_and_contained_links(self):
        self.install_fixture(self.root / "prefix")
        pg.check_layout(self.root / "prefix")
        for relative in ("bin/psql", "share/postgres.bki"):
            path = self.root / "prefix" / relative
            content = path.read_bytes()
            path.unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                pg.check_layout(self.root / "prefix")
            path.write_bytes(content)
        if os.name != "nt":
            link = self.root / "prefix/lib/libpq.so"
            link.symlink_to("libpq.so.5")
            pg.check_layout(self.root / "prefix")
            link.unlink()
            link.symlink_to("../../../escape")
            with self.assertRaisesRegex(ValueError, "escaping symlink"):
                pg.check_layout(self.root / "prefix")

    def test_linux_audit_rejects_missing_libraries_and_absolute_runtime_paths(self):
        self.install_fixture(self.root / "prefix")
        good = "(NEEDED) Shared library: [libpq.so.5]\n(NEEDED) Shared library: [libc.so.6]\n(RUNPATH) Library runpath: [$ORIGIN/../lib]\n"
        with patch.object(pg, "run", return_value=good):
            self.assertIn("bin/psql", pg.audit(self.root / "prefix", "linux-amd64", {}))
        for output in (good.replace("libpq.so.5", "libssl.so.3"),
                       good.replace("$ORIGIN/../lib", "/tmp/host/lib"),
                       good.replace("$ORIGIN/../lib", "$ORIGIN/../lib:/opt/homebrew/lib"),
                       "(NEEDED) Shared library: [libpq.so.5]"):
            with self.subTest(output=output), patch.object(pg, "run", return_value=output):
                with self.assertRaises(ValueError):
                    pg.audit(self.root / "prefix", "linux-amd64", {})

    def test_linux_system_loader_dependency_must_match_target_architecture(self):
        self.install_fixture(self.root / "prefix")
        for target, correct, wrong in (("linux-amd64", "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1"),
                                       ("linux-arm64", "ld-linux-aarch64.so.1", "ld-linux-x86-64.so.2")):
            with self.subTest(target=target), patch.object(pg, "run", return_value=f"(NEEDED) Shared library: [{correct}]\n"):
                pg.audit(self.root / "prefix", target, {})
            with self.subTest(target=target, wrong=wrong), patch.object(pg, "run", return_value=f"(NEEDED) Shared library: [{wrong}]\n"):
                with self.assertRaisesRegex(ValueError, "wrong-architecture"):
                    pg.audit(self.root / "prefix", target, {})

    def test_macos_relocation_changes_owned_dylibs_and_resigns_each_binary(self):
        prefix = self.root / "prefix"
        paths = [prefix / "bin/psql", prefix / "lib/libpq.5.dylib"]
        with patch.object(pg, "binary_files", return_value=iter(paths)), patch.object(pg, "run") as run:
            run.return_value = "file:\n /tesl-postgresql/lib/libpq.5.dylib (compatibility version 5.0)\n /usr/lib/libSystem.B.dylib (compatibility version 1.0)\n"
            pg.relocate_macos(prefix, {})
        commands = [call.args[0] for call in run.call_args_list]
        self.assertIn(["install_name_tool", "-change", "/tesl-postgresql/lib/libpq.5.dylib",
                       "@rpath/libpq.5.dylib", str(paths[0])], commands)
        self.assertIn(["install_name_tool", "-id", "@rpath/libpq.5.dylib", str(paths[1])], commands)
        self.assertEqual(sum(command[0] == "codesign" for command in commands), 2)

    def test_windows_builder_pins_tools_selects_msvc_and_disables_downloads(self):
        tools = {name: [name] for name in ("meson", "ninja", "perl", "flex", "bison")}
        self.plan["windowsBuildTools"] = {name: {"version": "1.2.3"} for name in tools}
        calls = []
        def run(arguments, directory, environment, capture=False):
            calls.append((arguments, environment))
            if arguments[-1] == "--version" or arguments[-1] == "print $^V":
                return "1.2.3"
            if arguments[-1] == "print $Config{osname}":
                return "MSWin32"
            if "introspect" in arguments:
                return json.dumps({"host": {"c": {"id": "msvc", "version": "19.44"}}})
        with patch.object(pg, "run", side_effect=run), patch.object(pg.shutil, "which", return_value=str(self.msvc)):
            arguments, evidence = pg.build_windows(self.plan, self.root / "source", self.root / "build",
                                                   self.root / "stage", {"PATH": "native", "CFLAGS": "-O2"}, tools, 2)
        self.assertIn("--wrap-mode=nodownload", arguments)
        self.assertIn("--auto-features=disabled", arguments)
        self.assertIn("-Dssl=none", arguments)
        self.assertIn("-Db_vscrt=mt", arguments)
        self.assertIn("--prefix=C:/tesl-postgresql", arguments)
        setup_env = next(environment for command, environment in calls if "setup" in command)
        self.assertEqual(setup_env["CC"], str(self.msvc))
        self.assertEqual(setup_env["PATH"].split(os.pathsep)[0], str(self.msvc.parent))
        self.assertNotIn("CFLAGS", setup_env)
        self.assertEqual(evidence["c"]["runtime_library"], "static")
        self.assertEqual(calls[-1][0][-1], "--no-rebuild")

    def test_windows_build_publishes_complete_exe_component_with_tool_evidence(self):
        from test_pe_audit import pe_image
        tools = {name: [name] for name in ("meson", "ninja", "perl", "flex", "bison")}
        self.plan["windowsBuildTools"] = {name: {"version": "1.2.3"} for name in tools}
        def run(arguments, directory, environment, capture=False):
            if arguments[0] in tools and (arguments[-1] == "--version" or arguments[-1] == "print $^V"):
                return "1.2.3"
            if arguments[-1] == "print $Config{osname}":
                return "MSWin32"
            if "introspect" in arguments:
                return json.dumps({"host": {"c": {"id": "msvc", "version": "19.44"}}})
            if "install" in arguments:
                prefix = Path(arguments[arguments.index("--destdir") + 1]) / "tesl-postgresql"
                self.install_fixture(prefix)
                for command in pg.COMMANDS:
                    (prefix / "bin" / command).unlink()
                    (prefix / "bin" / (command + ".exe")).write_bytes(pe_image(imports=["kernel32.dll"]))
                (prefix / "lib/libpq.so.5").unlink()
                (prefix / "bin/libpq.dll").write_bytes(pe_image(imports=["ucrtbase.dll"], dll=True))
            if arguments[-1] == "--version":
                return "PostgreSQL 17.10"
        with patch.object(pg, "native_target", return_value="windows-amd64"), \
                patch.object(pg, "extract_verified", side_effect=self.extract_fixture), \
                patch.object(pg, "run", side_effect=run), patch.object(pg.shutil, "which", return_value=str(self.msvc)):
            output = pg.build(self.plan, "windows-amd64", self.root / "archive", self.root / "output", windows_tools=tools)
        pg.check_layout(output, "windows-amd64")
        metadata = json.loads((output / "native-build.json").read_text())
        self.assertEqual(metadata["target"], "windows-amd64")
        self.assertEqual(metadata["build_tools"]["c"]["id"], "msvc")
        self.assertEqual(metadata["dependencies"]["bin/psql.exe"], ["kernel32.dll"])
        self.assertEqual(sorted(path.name for path in self.root.iterdir()), ["output"])

    def test_windows_builder_rejects_unpinned_tools_wrong_versions_and_cygwin_perl(self):
        tools = {name: [name] for name in ("meson", "ninja", "perl", "flex", "bison")}
        with self.assertRaisesRegex(ValueError, "Nix-declared"):
            pg.build_windows(self.plan, self.root, self.root, self.root, {}, tools, 2)
        self.plan["windowsBuildTools"] = {name: {"version": "1.2.3"} for name in tools}
        with patch.object(pg, "run", return_value="9.0.0"), self.assertRaisesRegex(ValueError, "differs from"):
            pg.build_windows(self.plan, self.root, self.root, self.root, {}, tools, 2)
        with patch.object(pg, "run", side_effect=["1.2.3"] * 5 + ["cygwin"]), self.assertRaisesRegex(ValueError, "native Perl"):
            pg.build_windows(self.plan, self.root, self.root, self.root, {}, tools, 2)
        with patch.object(pg, "run", side_effect=["1.2.3"] * 5 + ["MSWin32"]), \
                patch.object(pg.shutil, "which", return_value=None), self.assertRaisesRegex(ValueError, "MSVC developer"):
            pg.build_windows(self.plan, self.root, self.root, self.root, {}, tools, 2)
        with patch.object(pg, "run", side_effect=["1.2.3"] * 5 + ["MSWin32", None, '{"host":{"c":{"id":"gcc"}}}']), \
                patch.object(pg.shutil, "which", return_value=str(self.msvc)), self.assertRaisesRegex(ValueError, "select native MSVC"):
            pg.build_windows(self.plan, self.root, self.root, self.root, {}, tools, 2)

    def test_windows_layout_and_pe_closure_require_exe_tools_and_colocated_libraries(self):
        from test_pe_audit import pe_image
        prefix = self.root / "prefix"
        self.install_fixture(prefix)
        for command in pg.COMMANDS:
            (prefix / "bin" / command).unlink()
            (prefix / "bin" / (command + ".exe")).write_bytes(pe_image(imports=["kernel32.dll", "libpq.dll"]))
        (prefix / "lib/libpq.so.5").unlink()
        (prefix / "bin/libpq.dll").write_bytes(pe_image(imports=["ucrtbase.dll"], dll=True))
        pg.check_layout(prefix, "windows-amd64")
        dependencies = pg.audit(prefix, "windows-amd64", {})
        self.assertEqual(dependencies["bin/psql.exe"], ["kernel32.dll", "libpq.dll"])
        (prefix / "bin/libpq.dll").unlink()
        with self.assertRaisesRegex(ValueError, "unbundled Windows"):
            pg.audit(prefix, "windows-amd64", {})

    def test_macos_audit_rejects_host_library_paths(self):
        prefix = self.root / "prefix"
        self.install_fixture(prefix)
        (prefix / "lib/libpq.5.dylib").write_bytes(b"\xcf\xfa\xed\xfe fake")
        for library, succeeds in (("/usr/lib/libSystem.B.dylib", True), ("@rpath/libpq.5.dylib", True),
                                  ("/opt/homebrew/lib/libpq.5.dylib", False), ("@rpath/missing.dylib", False)):
            with self.subTest(library=library), patch.object(pg, "run", return_value="file:\n " + library + " (version)\n"):
                if succeeds:
                    pg.audit(prefix, "darwin-arm64", {})
                else:
                    with self.assertRaisesRegex(ValueError, "unbundled"):
                        pg.audit(prefix, "darwin-arm64", {})


if __name__ == "__main__":
    unittest.main()

"""Exercise orchestration identity, failed gates, extraction, and network isolation."""

from contextlib import ExitStack
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from unittest.mock import patch

import native_distribution as distribution


SHA = "1" * 40


def plan(target="linux-amd64"):
    version = "0.3.1"
    suffix = ".exe" if target.startswith("windows-") else ""
    commands = ["tesl", "tesl-lsp", "tesl-dap", "tesl-mcp", "tesl-debug-inspect", "tesl-debug-attach"]
    components = {name: {"path": "bin/" + name + suffix, "version": version} for name in commands}
    for name in distribution.native_payload.PG_COMMANDS:
        components[name] = {"path": "libexec/tesl/postgresql/bin/" + name + suffix, "version": "17.10"}
    for name, path in {"compiler": "libexec/tesl/tesl-compiler" + suffix, "go": "libexec/tesl/go/bin/go" + suffix,
                       **{name: "share/tesl/" + name for name in distribution.native_payload.DIRECTORIES}}.items():
        components[name] = {"path": path, "version": "1.26.6" if name == "go" else version}
    value = {"version": 1, "sourceRevision": SHA, "sourceDateEpoch": 1, "toolchainVersion": version,
            "release": {"publishableSource": True}, "commands": commands,
            "sources": {name: {"version": ver, "urls": ["https://example.test/" + name]}
                        for name, ver in {"go": "1.26.6", "ocaml": "5.4.1", "dune": "3.21.1", "postgresql": "17.10"}.items()},
            "candidates": [{"target": target, "baseline": "glibc 2.35" if target.startswith("linux-") else "macOS 13"}],
            "payloads": {target: {"archiveName": f"tesl-{version}-{target}" + (".zip" if target.startswith("windows-") else ".tar.gz"),
                                  "installerName": f"tesl-{version}-setup-{target}.exe",
                                  "manifest": {"version": 1, "target": target, "toolchain_version": version,
                                               "source_revision": SHA, "components": components}}}}
    if target.startswith("windows-"):
        value["windowsBuildTools"] = {name: {"version": "1.0", "urls": ["https://example.test/" + name]}
                                      for name in ("meson", "ninja", "perl", "flex", "bison")}
        value["windowsCompilerSources"] = {name: {"version": "1.0", "urls": ["https://example.test/" + name]}
                                           for name in ("flexdll", "winpthreads")}
        value["windowsRuntimeLicense"] = {"urls": ["https://example.test/runtime-license"]}
    return value


class Response(io.BytesIO):
    def __init__(self, content, url="https://example.test/source"):
        super().__init__(content)
        self.url = url

    def geturl(self):
        return self.url


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tesl distribution å ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / "result"

    def test_checkout_requires_exact_commit_and_clean_tracked_source(self):
        for revision, dirty in (("2" * 40, ""), (SHA, " M compiler/bin/main.ml")):
            with self.subTest(revision=revision, dirty=dirty), patch.object(distribution, "run", side_effect=[revision, dirty]):
                with self.assertRaisesRegex(ValueError, "planned commit"):
                    distribution.verify_checkout(plan(), self.root, {})
        with patch.object(distribution, "run", side_effect=[SHA, ""]):
            result = distribution.verify_checkout(plan(), self.root, {})
        self.assertEqual(result, {"head": SHA, "tracked_changes": False, "worktree_preview": False})

    def test_worktree_requires_explicit_nonpublishable_plan(self):
        value = plan()
        value["sourceRevision"] = "worktree"
        with patch.object(distribution, "run", side_effect=[SHA, " M source"]):
            with self.assertRaisesRegex(ValueError, "non-publishable"):
                distribution.verify_checkout(value, self.root, {})
        value["release"]["publishableSource"] = False
        with patch.object(distribution, "run", side_effect=[SHA, " M source"]):
            self.assertTrue(distribution.verify_checkout(value, self.root, {})["worktree_preview"])

    def test_download_records_actual_https_upgrade_and_redirect(self):
        with patch.object(distribution, "urlopen", return_value=Response(b"source", "https://cdn.example.test/source")) as opened:
            value = distribution.download({"urls": ["http://example.test/source"]}, self.root / "archive")
        self.assertEqual(opened.call_args.args[0], "https://example.test/source")
        self.assertEqual(value["final_url"], "https://cdn.example.test/source")
        self.assertEqual(value["archive_sha256"], distribution.native_payload.file_hash(self.root / "archive"))

    def test_download_falls_back_only_to_declared_mirrors_and_cleans_failures(self):
        with patch.object(distribution, "urlopen", side_effect=[OSError("first failed"), Response(b"second")]) as opened:
            distribution.download({"urls": ["https://one.test/source", "https://two.test/source"]}, self.root / "archive")
        self.assertEqual([call.args[0] for call in opened.call_args_list], ["https://one.test/source", "https://two.test/source"])
        self.assertEqual((self.root / "archive").read_bytes(), b"second")
        for source in ({"urls": []}, {"urls": ["file:///tmp/source"]}):
            with self.assertRaises(ValueError):
                distribution.download(source, self.root / "invalid")

    def test_download_byte_and_time_bounds_remove_partial_archive(self):
        for limit, ticks in ((2, [0, 0]), (1024, [0, 301])):
            with self.subTest(limit=limit), patch.object(distribution, "MAX_SOURCE_BYTES", limit), \
                    patch.object(distribution.time, "monotonic", side_effect=ticks), \
                    patch.object(distribution, "urlopen", return_value=Response(b"archive")):
                with self.assertRaisesRegex(ValueError, "bound"):
                    distribution.download({"urls": ["https://example.test/source"]}, self.root / "archive")
            self.assertFalse((self.root / "archive").exists())

    def test_download_preserves_existing_output(self):
        archive = self.root / "existing"
        archive.write_text("preserved")
        with self.assertRaisesRegex(ValueError, "already exists"):
            distribution.download({"urls": ["https://example.test/source"]}, archive)
        self.assertEqual(archive.read_text(), "preserved")

    def test_frontend_environment_selects_new_sdk_and_locked_local_proxy(self):
        env = distribution.build_environment({"PATH": "old", "GOPROXY": "https://invalid.test", "CGO_ENABLED": "1", "GOFLAGS": "-race"},
                                             "linux-amd64", self.root / "sdk", self.root / "work", self.root / "modules")
        self.assertEqual(env["GOROOT"], str(self.root / "sdk"))
        self.assertEqual(env["GOPROXY"], (self.root / "modules/proxy").as_uri())
        self.assertEqual(env["CGO_ENABLED"], "0")
        self.assertEqual(env["GONOPROXY"], "none")
        self.assertEqual(env["GOVCS"], "*:off")
        self.assertNotIn("GOFLAGS", env)

    def test_linux_isolation_preserves_user_and_macos_does_not_claim_namespace(self):
        args = distribution.acceptance_command("linux-amd64", self.root / "go", self.root)
        self.assertEqual(args[:5], ["unshare", "--user", "--map-current-user", "--keep-caps", "--net"])
        self.assertEqual(args[7], 'ip link set lo up && exec "$@"')
        self.assertIn("^TestInstalledToolchainWorkflow$", args)
        mac = distribution.acceptance_command("darwin-arm64", self.root / "go", self.root)
        self.assertEqual(mac[0], str(self.root / "go"))
        self.assertNotIn("unshare", mac)

    def test_ocaml_licenses_preserve_referenced_license_tree(self):
        source = self.root / "ocaml-source/ocaml-5.4.1"
        (source / "LICENSES").mkdir(parents=True)
        (source / "LICENSE").write_text("see LICENSES")
        (source / "LICENSES/LGPL.txt").write_text("license text")
        result = distribution.ocaml_licenses(source.parent, self.root / "licenses")
        self.assertEqual((result / "LICENSES/LGPL.txt").read_text(), "license text")

    def pipeline(self, failure=None, target="linux-amd64"):
        calls = []
        value = plan(target)

        def run(arguments, root, environment, capture=False, timeout=1800):
            args = list(map(str, arguments))
            calls.append((args, environment.copy()))
            if args[:3] == ["git", "rev-parse", "HEAD"]:
                return SHA
            if args[:2] == ["git", "status"]:
                return ""
            if args[:4] == ["opam", "exec", "--", "ocamlc"]:
                return "5.4.1"
            if args[:4] == ["opam", "exec", "--", "dune"] and "--version" in args:
                return "3.21.1"
            if args[:3] == ["go", "env", "GOROOT"]:
                return str(self.root / "bootstrap")
            if args[0] == "tar":
                with tarfile.open(args[2], "r:gz") as archive:
                    archive.extractall(args[4], filter="data")
            if "^TestInstalledToolchainWorkflow$" in args:
                installed = Path(environment["TESL_TEST_INSTALLED_ROOT"])
                self.assertEqual((installed / "fixture").read_text(), "tested extracted bytes")
                if failure == "acceptance":
                    raise subprocess.CalledProcessError(1, args)

        def download(source, output):
            output.write_bytes(b"pinned archive")
            return {"requested_url": source["urls"][0]}

        def sdk_build(plan, target, archive, bootstrap, output):
            self.assertTrue(output.is_absolute())
            output.mkdir()
            return output

        def pg_build(plan, target, archive, output, **options):
            if target.startswith("windows-"):
                self.assertIn("windows_tools", options)
            output.mkdir()
            return output

        def compiler_tools_build(plan, target, ocaml, dune, output, **options):
            if target.startswith("windows-"):
                self.assertEqual(set(options["windows_archives"]), {"flexdll", "winpthreads"})
                self.assertIn("cygwin_bash", options)
            output.mkdir()
            (output / "licenses").mkdir()
            (output / "licenses/LICENSE").write_text("OCaml license")
            return output

        def assemble(plan, root, target, compiler, frontends, sdk, pg, bundle, licenses, output, **options):
            if target.startswith("windows-"):
                self.assertIn("compiler_runtime", options)
            self.assertEqual((licenses / "LICENSE").read_text(), "OCaml license")
            if failure == "audit":
                raise ValueError("payload audit failed")
            output.mkdir()
            (output / "fixture").write_text("tested extracted bytes")
            return {"version": 1, "target": target, "binaries": []}

        def pack(plan, target, payload, output):
            if target.startswith("windows-"):
                with zipfile.ZipFile(output, "w") as archive:
                    archive.write(payload / "fixture", output.name.removesuffix(".zip") + "/fixture")
            else:
                with tarfile.open(output, "w:gz") as archive:
                    archive.add(payload, arcname=output.name.removesuffix(".tar.gz"))
            return distribution.native_payload.file_hash(output)

        stack = ExitStack()
        self.addCleanup(stack.close)
        for owner, name, callback in ((distribution, "run", run), (distribution, "download", download),
                                     (distribution.native_compiler_tools, "build", compiler_tools_build), (distribution.native_sdk, "build", sdk_build),
                                     (distribution.native_postgres, "build", pg_build), (distribution.native_payload, "assemble", assemble),
                                     (distribution.native_payload, "pack", pack)):
            stack.enter_context(patch.object(owner, name, side_effect=callback))
        stack.enter_context(patch.object(distribution, "verify_module_bundle"))
        stack.enter_context(patch.object(distribution.native_sdk, "host_target", return_value=target))
        stack.enter_context(patch.object(distribution.native_host, "runtime_evidence", return_value={
            "minimum_os_runtime": "not-established", "acceptance_host": {"matches_baseline": False}}))
        if target.startswith("darwin-"):
            def isolated(arguments, root, environment, timeout):
                run(arguments, root, environment, timeout=timeout)
                if failure == "network":
                    raise ValueError("outbound network remains reachable")
                return {"network_isolation": "macos-sandbox-exec", "host_local_only_reachability": "passed"}
            stack.enter_context(patch.object(distribution.macos_network, "run", side_effect=isolated))
        if target.startswith("windows-"):
            stack.enter_context(patch.object(distribution.native_windows_tools, "provision", return_value={"verified": True}))
            stack.enter_context(patch.object(distribution.native_compiler_tools, "collect_windows_runtime", return_value=self.root / "runtime"))
            stack.enter_context(patch.object(distribution, "windows_setup", return_value={"authenticode": "unsigned"}))
        return value, calls

    def test_full_pipeline_only_exports_archive_after_extracted_acceptance(self):
        value, calls = self.pipeline()
        result = distribution.build(value, self.root, "linux-amd64", self.root / "module-bundle", self.output)
        self.assertTrue((self.output / result["archive"]).is_file())
        self.assertTrue((self.output / (result["archive"] + ".sha256")).is_file())
        evidence = json.loads((self.output / "distribution-checks.json").read_text())
        self.assertEqual(evidence["installed_workflow"], "passed")
        self.assertEqual(evidence["network_isolation"], "linux-network-namespace")
        self.assertTrue(evidence["ocaml"]["compiler_source_hash_verified"])
        self.assertTrue(evidence["dune"]["source_hash_verified"])
        self.assertFalse(any(args[0] == "opam" for args, _ in calls))
        self.assertFalse(evidence["published"])
        self.assertEqual(evidence["minimum_os_runtime"], "not-established")
        build_calls = [args for args, _ in calls if "./cmd/..." in args]
        self.assertEqual(len(build_calls), 1)
        self.assertIn("-trimpath", build_calls[0])
        self.assertIn("-buildvcs=false", build_calls[0])
        self.assertIn("-ldflags", build_calls[0])
        self.assertFalse(list(self.root.glob(".tesl-distribution-*")))

    def test_failed_audit_or_acceptance_never_exports_success_artifacts(self):
        for failure in ("audit", "acceptance"):
            with self.subTest(failure=failure):
                value, calls = self.pipeline(failure)
                expected = ValueError if failure == "audit" else subprocess.CalledProcessError
                message = "payload audit failed" if failure == "audit" else "TestInstalledToolchainWorkflow"
                with self.assertRaisesRegex(expected, message):
                    distribution.build(value, self.root, "linux-amd64", self.root / "modules", self.output)
                acceptance_ran = any("^TestInstalledToolchainWorkflow$" in args for args, _ in calls)
                self.assertEqual(acceptance_ran, failure == "acceptance")
                self.assertFalse(self.output.exists())
                self.assertFalse(list(self.root.glob(".tesl-distribution-*")))

    def test_macos_records_probed_network_isolation_and_retains_minimum_os_limitation(self):
        value, calls = self.pipeline(target="darwin-arm64")
        result = distribution.build(value, self.root, "darwin-arm64", self.root / "modules", self.output)
        self.assertEqual(result["network_isolation"], "macos-sandbox-exec")
        self.assertEqual(result["host_local_only_reachability"], "passed")
        self.assertEqual(result["minimum_os_runtime"], "not-established")
        self.assertEqual(result["signed_distribution"], "ad-hoc-by-policy")
        self.assertEqual(result["quarantined_download"], "not-tested")
        self.assertTrue(all(environment["MACOSX_DEPLOYMENT_TARGET"] == "13" for _, environment in calls))

    def test_macos_failed_network_probe_never_exports_candidate(self):
        value, _ = self.pipeline(target="darwin-arm64", failure="network")
        with self.assertRaisesRegex(ValueError, "outbound network"):
            distribution.build(value, self.root, "darwin-arm64", self.root / "modules", self.output)
        self.assertFalse(self.output.exists())

    def test_windows_and_existing_output_fail_before_build(self):
        with self.assertRaisesRegex(ValueError, "explicit Cygwin"):
            distribution.build(plan("windows-amd64"), self.root, "windows-amd64", self.root / "modules", self.output)
        self.output.mkdir()
        with patch.object(distribution.native_sdk, "host_target", return_value="linux-amd64"):
            with self.assertRaisesRegex(ValueError, "already exists"):
                distribution.build(plan(), self.root, "linux-amd64", self.root / "modules", self.output)

    def test_windows_uses_verified_build_tools_native_executables_and_zip(self):
        value, calls = self.pipeline(target="windows-amd64")
        result = distribution.build(value, self.root, "windows-amd64", self.root / "modules", self.output,
                                    cygwin_bash=self.root / "cygwin/bin/bash.exe")
        self.assertEqual(result["signed_distribution"], "unsigned-by-policy")
        self.assertEqual(result["setup"]["authenticode"], "unsigned")
        self.assertEqual(result["installed_workflow"], "passed")
        self.assertTrue(zipfile.is_zipfile(self.output / result["archive"]))
        build = next(args for args, _ in calls if "./cmd/..." in args)
        self.assertTrue(build[0].endswith("go.exe"))
        compiler = next(args for args, _ in calls if "bin/main.exe" in args)
        self.assertTrue(compiler[0].endswith("dune.exe"))
        self.assertIn("compiler-winpthreads", result["source_downloads"])
        self.assertIn("build-perl", result["source_downloads"])
        self.assertFalse(any(args[0] == "tar" for args, _ in calls))

    def test_final_windows_setup_is_installed_launched_and_uninstalled_before_checksum_export(self):
        value = plan("windows-amd64")
        frontends, artifacts, work = (self.root / name for name in ("frontends", "artifacts", "work"))
        for directory in (frontends, artifacts, work):
            directory.mkdir()
        (frontends / "tesl-install.exe").write_bytes(b"MZ" + b"native bootstrap" * 20)
        archive = self.root / "portable.zip"
        with zipfile.ZipFile(archive, "w") as stream:
            stream.writestr("payload/fixture", "tested portable bytes")
        digest = distribution.native_payload.file_hash(archive)
        calls = []
        system_root = self.root / "Custom Windows"

        def run(arguments, root, environment, capture=False):
            self.assertEqual(environment["PATH"], str(system_root / "System32"))
            self.assertFalse(any(key.upper().startswith("TESL_") for key in environment))
            args = list(map(str, arguments))
            calls.append(args)
            self.assertNotIn("TESL_COMPILER", environment)
            self.assertTrue(environment["PATH"].endswith("System32"))
            if args[1] == "install":
                self.assertNotIn("--archive", args)
                return json.dumps({"state": {"active_version": value["toolchainVersion"]}})
            if args[1] == "version":
                return "tesl " + value["toolchainVersion"] + "\n"
            if args[1] == "doctor":
                return json.dumps({"ok": True, "toolchain_version": value["toolchainVersion"], "source_revision": SHA,
                                   "root": str(work / "installed by setup å/versions" / value["toolchainVersion"])})
            self.assertEqual(args[1], "uninstall")
            return json.dumps({"state": {"active_version": ""}, "installed": []})

        with patch.object(distribution, "audit_windows_binary", return_value=({"imports": ["kernel32.dll"]}, [])), \
                patch.object(distribution, "run", side_effect=run):
            result = distribution.windows_setup(value, frontends, archive, digest, artifacts, work,
                                                {"TESL_COMPILER": "unrelated", "tesl_toolchain_root": "unrelated",
                                                 "SYSTEMROOT": str(system_root), "PATH": "developer tools"})
        self.assertEqual([args[1] for args in calls], ["install", "version", "doctor", "uninstall"])
        self.assertEqual(result["authenticode"], "unsigned")
        self.assertEqual(result["install_launch_uninstall"], "passed")
        self.assertEqual(result["sha256"], distribution.native_payload.file_hash(artifacts / result["archive"]))
        self.assertTrue((artifacts / (result["archive"] + ".sha256")).is_file())


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Build an audited native archive and test its extracted installation, without publishing."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import zipfile
from urllib.parse import urlparse
from urllib.request import urlopen

import native_payload
import native_compiler_tools
import native_postgres
import native_sdk
import native_windows_tools
import installer_artifact
import macos_network
import native_host
from pe_audit import audit_binary as audit_windows_binary
from module_proxy import verify as verify_module_bundle
from native_source import MAX_SOURCE_BYTES, extract_verified


def run(arguments, root, environment, capture=False, timeout=1800):
    print("Native distribution: " + " ".join(map(str, arguments)), flush=True)
    result = subprocess.run(list(map(str, arguments)), cwd=root, env=environment,
                            check=True, text=True, capture_output=capture, timeout=timeout)
    return result.stdout.strip() if capture else None


def verify_checkout(plan, root, environment):
    revision = run(["git", "rev-parse", "HEAD"], root, environment, capture=True, timeout=30)
    dirty = run(["git", "status", "--porcelain", "--untracked-files=no"], root,
                environment, capture=True, timeout=30)
    if plan.get("sourceRevision") == "worktree":
        if plan.get("release", {}).get("publishableSource") is not False:
            raise ValueError("worktree preview requires explicit non-publishable source identity")
    elif (not re.fullmatch(r"[0-9a-f]{40}", plan.get("sourceRevision", ""))
          or revision != plan["sourceRevision"] or dirty):
        raise ValueError("distribution requires the planned commit with clean tracked source; "
                         f"planned={plan['sourceRevision']}, actual={revision}, tracked changes={dirty!r}")
    return {"head": revision, "tracked_changes": bool(dirty),
            "worktree_preview": plan["sourceRevision"] == "worktree"}


def download(source, output):
    """Fetch a declared source with byte, socket, and overall time bounds.

    Hash verification happens before extraction/build in extract_verified. HTTP
    is accepted only because the authoritative OCaml input currently uses it;
    the pinned SRI digest, rather than the transport, authenticates those bytes.
    """
    if output.exists() or output.is_symlink():
        raise ValueError("source download output already exists")
    urls = source.get("urls", [])
    if not isinstance(urls, list) or not urls:
        raise ValueError("source has no declared download URLs")
    errors, attempts = [], []
    for url in urls:
        if not isinstance(url, str) or urlparse(url).scheme not in {"http", "https"}:
            raise ValueError("source URL must use HTTP or HTTPS")
        # Same-host HTTPS is preferable for legacy HTTP declarations. The exact
        # archive still has to satisfy the Nix-pinned source hash before use.
        if url.startswith("http://"):
            attempts.append("https://" + url[7:])
        attempts.append(url)
    for url in dict.fromkeys(attempts):
        try:
            started, size = time.monotonic(), 0
            with urlopen(url, timeout=30) as response, output.open("xb") as stream:
                if urlparse(response.geturl()).scheme not in {"http", "https"}:
                    raise ValueError("source redirect uses an unsupported protocol")
                while data := response.read(1024 * 1024):
                    size += len(data)
                    if size > MAX_SOURCE_BYTES or time.monotonic() - started > 300:
                        raise ValueError("source download exceeds its size or time bound")
                    stream.write(data)
            return {"requested_url": url, "final_url": response.geturl(),
                    "archive_sha256": native_payload.file_hash(output)}
        except (OSError, ValueError) as error:
            output.unlink(missing_ok=True)
            errors.append(str(error))
    raise ValueError("source download failed: " + "; ".join(errors))


def build_environment(environment, target, sdk, work, module_bundle):
    result = native_sdk.build_environment(environment, target, sdk, work)
    result.update(GOROOT=str(sdk), PATH=str(sdk / "bin") + os.pathsep + environment.get("PATH", ""),
                  GOPROXY=(module_bundle / "proxy").as_uri(), GONOPROXY="none",
                  GOPRIVATE="", GONOSUMDB="none", GOVCS="*:off")
    return result


def acceptance_command(target, go, root):
    arguments = [str(go), "-C", str(root / "runtime/go"), "test", "./internal/cli",
                 "-run", "^TestInstalledToolchainWorkflow$", "-count=1", "-timeout=20m", "-v"]
    if target.startswith("linux-"):
        # Preserve the invoking UID so PostgreSQL does not see uid 0. Only the
        # new namespace receives capabilities needed to bring up loopback.
        arguments = ["unshare", "--user", "--map-current-user", "--keep-caps", "--net",
                     "sh", "-c", 'ip link set lo up && exec "$@"', "sh", *arguments]
    return arguments


def ocaml_licenses(source, output):
    directory = source
    if not (directory / "LICENSE").is_file():
        children = list(source.iterdir())
        if len(children) != 1 or not children[0].is_dir():
            raise ValueError("OCaml source has no unique licensed root")
        directory = children[0]
    if not (directory / "LICENSE").is_file():
        raise ValueError("OCaml source license is missing")
    output.mkdir()
    shutil.copyfile(directory / "LICENSE", output / "LICENSE")
    if (directory / "LICENSES").is_dir():
        shutil.copytree(directory / "LICENSES", output / "LICENSES")
    return output


def windows_setup(plan, frontends, archive, digest, artifacts, work, environment):
    bootstrap = frontends / "tesl-install.exe"
    detail, dependencies = audit_windows_binary(frontends, bootstrap, frontends)
    if dependencies:
        raise ValueError("standalone installer requires a non-system DLL")
    name = plan["payloads"]["windows-amd64"]["installerName"]
    if Path(name).name != name or not name.endswith(".exe"):
        raise ValueError("invalid Windows setup artifact name")
    executable = artifacts / name
    checksum = installer_artifact.bundle(bootstrap, archive, digest, executable)
    manager = work / "installed by setup å"
    # Test the actual downloadable executable and its embedded payload. The
    # clean-host workflow already exercised that ZIP's complete runtime above.
    isolated = {key.upper(): value for key, value in environment.items()
                if not key.upper().startswith("TESL_")}
    isolated["PATH"] = str(Path(isolated.get("SYSTEMROOT", r"C:\Windows")) / "System32")
    result = json.loads(run([executable, "install", "--root", manager, "--json"], work, isolated, capture=True))
    if result.get("state", {}).get("active_version") != plan["toolchainVersion"]:
        raise ValueError("setup selected an unexpected version")
    launcher = manager / "bin/tesl.exe"
    if run([launcher, "version"], work, isolated, capture=True).splitlines()[:1] != ["tesl " + plan["toolchainVersion"]]:
        raise ValueError("installed setup launcher reports an unexpected version")
    doctor = json.loads(run([launcher, "doctor", "--json"], work, isolated, capture=True))
    expected_root = (manager / "versions" / plan["toolchainVersion"]).resolve()
    if (doctor.get("ok") is not True or doctor.get("toolchain_version") != plan["toolchainVersion"]
            or doctor.get("source_revision") != plan["sourceRevision"]
            or Path(doctor.get("root", "")).resolve() != expected_root):
        raise ValueError("installed setup doctor does not report the selected complete toolchain")
    state = json.loads(run([executable, "uninstall", plan["toolchainVersion"], "--root", manager, "--json"],
                           work, isolated, capture=True))
    if state.get("state", {}).get("active_version") != "" or state.get("installed") != []:
        raise ValueError("setup uninstall did not remove its selected version")
    if native_payload.file_hash(executable) != checksum:
        raise ValueError("setup executable changed during acceptance")
    (artifacts / (name + ".sha256")).write_text(f"{checksum}  {name}\n", encoding="utf-8")
    return {"archive": name, "sha256": checksum, "embedded_archive_sha256": digest,
            "install_launch_uninstall": "passed", "authenticode": "unsigned", "binary_audit": detail}


def build(plan, root, target, module_bundle, output, cygwin_bash=None):
    root, module_bundle, output = Path(root).resolve(), Path(module_bundle).resolve(), Path(output).absolute()
    native_payload.payload_contract(plan, target)
    windows = target.startswith("windows-")
    suffix = ".exe" if windows else ""
    if windows and cygwin_bash is None:
        raise ValueError("Windows distribution requires an explicit Cygwin build environment")
    if target != native_sdk.host_target():
        raise ValueError("distribution builder requires the native target host")
    if output.exists() or output.is_symlink():
        raise ValueError("distribution output already exists")
    environment = dict(os.environ)
    if target.startswith("darwin-"):
        candidate = next(row for row in plan["candidates"] if row["target"] == target)
        match = re.fullmatch(r"macOS ([0-9]+(?:\.[0-9]+)*)", candidate.get("baseline", ""))
        if not match:
            raise ValueError("missing or invalid macOS baseline in release plan")
        environment["MACOSX_DEPLOYMENT_TARGET"] = match[1]
    source_identity = verify_checkout(plan, root, environment)
    verify_module_bundle(plan, root, module_bundle)
    bootstrap = Path(run(["go", "env", "GOROOT"], root, environment, capture=True)).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".tesl-distribution-", dir=output.parent) as temporary:
        work = Path(temporary)
        archives = {name: work / (name + ".tar") for name in ("go", "postgresql", "ocaml", "dune")}
        downloads = {name: download(plan["sources"][name], archive) for name, archive in archives.items()}
        sdk = native_sdk.build(plan, target, archives["go"], bootstrap, work / "sdk")
        windows_tools, windows_archives = None, {}
        if windows:
            tool_archives = {}
            for name, source in plan["windowsBuildTools"].items():
                tool_archives[name] = work / ("build-" + name + ".tar")
                downloads["build-" + name] = download(source, tool_archives[name])
            for name, source in plan["windowsCompilerSources"].items():
                windows_archives[name] = work / ("compiler-" + name + ".tar")
                downloads["compiler-" + name] = download(source, windows_archives[name])
            windows_tools = native_windows_tools.provision(plan, tool_archives, work / "windows-build-tools", cygwin_bash)
            runtime_license = work / "msvc-runtime-license.docx"
            downloads["msvc-runtime-license"] = download(plan["windowsRuntimeLicense"], runtime_license)
        postgres_options = {"windows_tools": windows_tools} if windows else {}
        postgres = native_postgres.build(plan, target, archives["postgresql"], work / "postgres", **postgres_options)
        compiler_options = {"windows_archives": windows_archives, "cygwin_bash": cygwin_bash} if windows else {}
        compiler_tools = native_compiler_tools.build(plan, target, archives["ocaml"], archives["dune"], work / "compiler-tools", **compiler_options)
        licenses = compiler_tools / "licenses"
        build_env = build_environment(environment, target, sdk, work / "build", module_bundle)
        build_env = native_compiler_tools.build_environment(build_env, plan, target, compiler_tools)
        run([compiler_tools / "bin" / ("dune" + suffix), "build", "--profile", "release", "bin/main.exe"],
            root / "compiler", build_env)
        compiler_runtime = None
        if windows:
            compiler_runtime = native_compiler_tools.collect_windows_runtime(
                root / "compiler/_build/default/bin/main.exe", compiler_tools, plan, environment, runtime_license)
        frontends = work / "frontends"
        frontends.mkdir()
        flags = (f"-X=tesl.dev/runtime/go/internal/toolchain.buildVersion={plan['toolchainVersion']} "
                 f"-X=tesl.dev/runtime/go/internal/toolchain.buildRevision={plan['sourceRevision']}")
        run([sdk / "bin" / ("go" + suffix), "build", "-trimpath", "-buildvcs=false", "-ldflags", flags,
             "-o", str(frontends) + os.sep, "./cmd/..."], root / "runtime/go", build_env)
        if verify_checkout(plan, root, environment) != source_identity:
            raise ValueError("tracked source identity changed during native build")
        payload = work / "payload"
        payload_options = {"compiler_runtime": compiler_runtime} if windows else {}
        audit = native_payload.assemble(plan, root, target, root / "compiler/_build/default/bin/main.exe",
                                        frontends, sdk, postgres, module_bundle, licenses, payload, **payload_options)
        artifacts = work / "artifacts"
        artifacts.mkdir()
        archive = artifacts / plan["payloads"][target]["archiveName"]
        digest = native_payload.pack(plan, target, payload, archive)
        (artifacts / (archive.name + ".sha256")).write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
        unpacked = work / "unpacked"
        unpacked.mkdir()
        # This archive was just assembled and audited above, not supplied by an
        # external caller. Native tar preserves its relative links and modes.
        if windows:
            with zipfile.ZipFile(archive) as stream:
                stream.extractall(unpacked)
        else:
            run(["tar", "-xzf", archive, "-C", unpacked], root, environment)
        installed = unpacked / archive.name.removesuffix(".tar.gz").removesuffix(".zip")
        test_env = dict(build_env, TESL_TEST_INSTALLED_ROOT=str(installed))
        acceptance = acceptance_command(target, sdk / "bin" / ("go" + suffix), root)
        network = {"network_isolation": "linux-network-namespace" if target.startswith("linux-") else "not-tested"}
        if target.startswith("darwin-"):
            network = macos_network.run(acceptance, root, test_env, timeout=1500)
        else:
            run(acceptance, root, test_env, timeout=1500)
        if native_payload.file_hash(archive) != digest:
            raise ValueError("archive changed during installed acceptance")
        setup = windows_setup(plan, frontends, archive, digest, artifacts, work, environment) if windows else None
        evidence = {
            "version": 1, "target": target, "toolchain_version": plan["toolchainVersion"],
            "source_revision": plan["sourceRevision"], "checkout": source_identity,
            "archive": archive.name, "sha256": digest, "candidate_only": True,
            "installed_workflow": "passed", "payload_audit": audit,
            **network,
            **native_host.runtime_evidence(plan, target),
            "signed_distribution": "unsigned-by-policy" if windows else "ad-hoc-by-policy" if target.startswith("darwin-") else "not-required",
            "quarantined_download": "not-tested",
            "setup": setup,
            "published": False,
            "source_downloads": downloads,
            "sources": {"go": plan["sources"]["go"], "postgresql": plan["sources"]["postgresql"]},
            "ocaml": {"version": plan["sources"]["ocaml"]["version"], "selection": "verified-source-build",
                      "compiler_source_hash_verified": True,
                      "license_source": plan["sources"]["ocaml"]},
            "dune": {"version": plan["sources"]["dune"]["version"], "selection": "verified-source-build", "source_hash_verified": True},
        }
        (artifacts / "distribution-checks.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        artifacts.rename(output)
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("plan", "module-bundle", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--cygwin-bash", type=Path, help="Native Windows build-only Cygwin bash.exe")
    args = parser.parse_args()
    try:
        build(json.loads(args.plan.read_text(encoding="utf-8")), Path(__file__).resolve().parent.parent,
              args.target, args.module_bundle, args.output, args.cygwin_bash)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(f"native distribution failed: {error}") from error
    print(f"Candidate archive and installed-workflow evidence: {args.output}")


if __name__ == "__main__":
    main()

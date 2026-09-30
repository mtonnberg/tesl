#!/usr/bin/env python3
"""Build a relocatable local PostgreSQL component from Nix-pinned source.

This intentionally minimal managed server excludes optional TLS, ICU, compression
and language dependencies. It does not replace a production PostgreSQL package.
Windows uses native MSVC/Meson with static CRT linkage and an audited DLL closure.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
from native_msvc import prefer_msvc

from native_source import extract_verified
from pe_audit import audit_binary


PREFIX = "/tesl-postgresql"
COMMANDS = ("postgres", "initdb", "pg_ctl", "createdb", "psql")
DISABLED = ("icu", "readline", "zlib", "lz4", "zstd", "ssl", "gssapi", "ldap",
            "pam", "bsd-auth", "bonjour", "selinux", "systemd", "llvm", "perl",
            "python", "tcl", "libxml", "libxslt")
LINUX_SYSTEM_LOADERS = {"linux-amd64": "ld-linux-x86-64.so.2",
                        "linux-arm64": "ld-linux-aarch64.so.1"}
LINUX_SYSTEM_LIBRARIES = frozenset(("libc.so.6", "libm.so.6", "libresolv.so.2",
                                  "libpthread.so.0", "libdl.so.2", "librt.so.1",
                                  "libutil.so.1"))


def native_target():
    system = {"Linux": "linux", "Darwin": "darwin", "Windows": "windows"}.get(platform.system())
    architecture = {"x86_64": "amd64", "AMD64": "amd64", "aarch64": "arm64",
                    "arm64": "arm64"}.get(platform.machine())
    return f"{system}-{architecture}"


def validate(plan, target, jobs):
    if plan.get("version") != 1:
        raise ValueError("unsupported native release plan")
    if target not in {row["target"] for row in plan.get("candidates", [])}:
        raise ValueError("target absent from Nix release plan")
    if target not in {"linux-amd64", "linux-arm64", "darwin-amd64", "darwin-arm64", "windows-amd64"}:
        raise ValueError("unsupported native PostgreSQL target")
    if target != native_target():
        raise ValueError("PostgreSQL target does not match the native host")
    if isinstance(jobs, bool) or not isinstance(jobs, int) or jobs < 1:
        raise ValueError("jobs must be a positive integer")
    source = plan.get("sources", {}).get("postgresql", {})
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", source.get("version", "")):
        raise ValueError("invalid PostgreSQL version in release plan")
    return source


def build_environment(plan, target=None):
    # Explicit flags prevent developer-shell injection of optional runtime libs,
    # build-directory rpaths, or CPU-specific optimization into release binaries.
    environment = {key: value for key, value in os.environ.items()
                   if key not in {"CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LIBS",
                                  "LDFLAGS_EX", "LDFLAGS_SL", "MAKEFLAGS", "MFLAGS",
                                  "MAKELEVEL", "CONFIG_SITE", "LD_LIBRARY_PATH",
                                  "DYLD_LIBRARY_PATH", "CPATH", "LIBRARY_PATH",
                                  "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH"}
                   and not key.startswith(("PKG_CONFIG", "NIX_", "ICU_", "XML2_", "LZ4_", "ZSTD_",
                                           "DYLD_", "LD_", "ac_cv_", "pgac_cv_", "with_", "enable_"))}
    environment.update(LC_ALL="C", TZ="UTC", CFLAGS="-O2", CXXFLAGS="-O2",
                       CONFIG_SITE="/dev/null", MAKELEVEL="0",
                       SOURCE_DATE_EPOCH=str(plan.get("sourceDateEpoch", 0)))
    selected_target = target or native_target()
    if selected_target.startswith("darwin-"):
        candidate = next((row for row in plan["candidates"] if row["target"] == selected_target), {})
        match = re.fullmatch(r"macOS ([0-9]+(?:\.[0-9]+)*)", candidate.get("baseline", ""))
        if not match:
            raise ValueError("missing or invalid macOS baseline in release plan")
        environment["MACOSX_DEPLOYMENT_TARGET"] = match[1]
    return environment


def configure_arguments(source_directory):
    return [str(source_directory / "configure"), "--prefix=" + PREFIX,
            "--disable-nls", "--disable-debug", "--disable-cassert",
            *["--without-" + feature for feature in DISABLED if feature != "ssl"],
            "--without-openssl"]


def make_arguments(target):
    if target.startswith("linux-"):
        # Make consumes one '$'; the shell's quotes preserve the second one for
        # the ELF loader. Arguments reach make directly, without a shell layer.
        return ["rpath=-Wl,-rpath,'$$ORIGIN/../lib'"]
    return ["rpath=-Wl,-rpath,@loader_path/../lib"]


def run(arguments, directory, environment, capture=False):
    result = subprocess.run(arguments, cwd=directory, env=environment, check=True,
                            text=True, capture_output=capture)
    return result.stdout if capture else None


def binary_files(prefix):
    for path in sorted(prefix.rglob("*")):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                magic = stream.read(4)
            if magic[:2] == b"MZ" or magic in (b"\x7fELF", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
                yield path


def relocate_macos(prefix, environment):
    for path in binary_files(prefix):
        libraries = run(["otool", "-L", str(path)], prefix, environment, capture=True)
        for line in libraries.splitlines()[1:]:
            name = line.strip().split(" (", 1)[0]
            if name.startswith(PREFIX + "/lib/"):
                relative = "@rpath/" + name.removeprefix(PREFIX + "/lib/")
                if path.parent == prefix / "lib" and path.name == Path(name).name:
                    run(["install_name_tool", "-id", relative, str(path)], prefix, environment)
                else:
                    run(["install_name_tool", "-change", name, relative, str(path)], prefix, environment)
        # Altering load commands invalidates the linker-generated arm64 signature.
        run(["codesign", "--force", "--sign", "-", str(path)], prefix, environment)


def audit(prefix, target, environment):
    dependencies = {}
    for path in binary_files(prefix):
        relative = path.relative_to(prefix).as_posix()
        if target.startswith("windows-"):
            detail, _ = audit_binary(prefix, path, prefix / "bin")
            libraries = detail["imports"] + detail["delay_imports"] + detail["forwarded_imports"]
        elif target.startswith("linux-"):
            output = run(["readelf", "-d", str(path)], prefix, environment, capture=True)
            libraries = re.findall(r"\(NEEDED\).*\[([^]]+)\]", output)
            rpaths = re.findall(r"\((?:RPATH|RUNPATH)\).*\[([^]]+)\]", output)
            if any(value != "$ORIGIN/../lib" for value in rpaths):
                raise ValueError(f"unexpected PostgreSQL library path in {relative}: {rpaths}")
            for library in libraries:
                if library in LINUX_SYSTEM_LOADERS.values() and library != LINUX_SYSTEM_LOADERS[target]:
                    raise ValueError(f"wrong-architecture PostgreSQL system loader in {relative}: {library}")
                if library in LINUX_SYSTEM_LIBRARIES or library == LINUX_SYSTEM_LOADERS[target]:
                    continue
                if "/" in library or not (prefix / "lib" / library).is_file() or not rpaths:
                    raise ValueError(f"unbundled PostgreSQL dependency in {relative}: {library}")
        else:
            output = run(["otool", "-L", str(path)], prefix, environment, capture=True)
            libraries = [line.strip().split(" (", 1)[0] for line in output.splitlines()[1:]]
            for library in libraries:
                if library.startswith(("/usr/lib/", "/System/Library/")):
                    continue
                if not library.startswith("@rpath/") or not (prefix / "lib" / library[7:]).is_file():
                    raise ValueError(f"unbundled PostgreSQL dependency in {relative}: {library}")
        dependencies[relative] = libraries
    if not dependencies:
        raise ValueError("PostgreSQL installation contains no native binaries")
    return dependencies


def check_layout(prefix, target="linux-amd64"):
    suffix = ".exe" if target.startswith("windows-") else ""
    for command in COMMANDS:
        if not (prefix / "bin" / (command + suffix)).is_file():
            raise ValueError(f"PostgreSQL installation is missing {command}")
    for relative in ("share/postgres.bki", "share/postgresql.conf.sample", "share/timezone", "lib"):
        if not (prefix / relative).exists():
            raise ValueError(f"PostgreSQL installation is missing {relative}")
    # Preserve relative links, but never package links outside the component.
    for path in prefix.rglob("*"):
        if path.is_symlink():
            if os.path.isabs(os.readlink(path)) or not path.resolve().is_relative_to(prefix.resolve()):
                raise ValueError(f"PostgreSQL installation contains an escaping symlink: {path}")


def build_windows(plan, source, directory, staged, environment, tools, jobs):
    """Use explicitly provisioned build tools; never download implicit fallbacks."""
    names = ("meson", "ninja", "perl", "flex", "bison")
    pins = plan.get("windowsBuildTools", {})
    if not isinstance(tools, dict) or set(tools) != set(names) or any(name not in pins for name in names):
        raise ValueError("Windows PostgreSQL requires Nix-declared and provisioned meson/ninja/perl/flex/bison tools")
    evidence = {}
    for name in names:
        command = tools[name]
        if (not isinstance(command, list) or not command or
                any(not isinstance(item, str) or not item for item in command) or
                (name != "meson" and len(command) != 1)):
            raise ValueError(f"invalid Windows build tool command: {name}")
        arguments = ["-e", "print $^V"] if name == "perl" else ["--version"]
        reported = run([*command, *arguments], directory, environment, capture=True).strip()
        expected = pins[name].get("version", "")
        match = re.search(r"(?<![0-9.])v?([0-9]+(?:\.[0-9]+)+)(?![0-9.])", reported)
        if not match or match[1] != expected:
            raise ValueError(f"Windows {name} version differs from the Nix release plan: {reported}")
        evidence[name] = {"version": expected, "selection": "version-verified-build-tool"}
    perl_os = run([*tools["perl"], "-MConfig", "-e", "print $Config{osname}"],
                  directory, environment, capture=True).strip()
    if perl_os != "MSWin32":
        raise ValueError("PostgreSQL Windows builds require native Perl, not Cygwin/MSYS Perl")
    compiler = shutil.which("cl.exe", path=environment.get("PATH", ""))
    if not compiler:
        raise ValueError("PostgreSQL Windows builds require the native x64 MSVC developer environment")
    build_env = prefer_msvc(dict(environment, CC=compiler, CXX=compiler, NINJA=tools["ninja"][0]), compiler)
    build_env.pop("CFLAGS", None)
    build_env.pop("CXXFLAGS", None)
    arguments = [*tools["meson"], "setup", str(directory), str(source),
                 "--prefix=C:" + PREFIX, "--libdir=lib", "--datadir=share", "--buildtype=release",
                 "--auto-features=disabled", "--wrap-mode=nodownload", "-Dssl=none", "-Duuid=none",
                 "-Drpath=false", "-Db_vscrt=mt"]
    for option, name in (("PERL", "perl"), ("FLEX", "flex"), ("BISON", "bison")):
        arguments.append("-D" + option + "=" + tools[name][0])
    run(arguments, directory, build_env)
    compilers = json.loads(run([*tools["meson"], "introspect", "--compilers", str(directory)],
                              directory, build_env, capture=True))
    if compilers.get("host", {}).get("c", {}).get("id") != "msvc":
        raise ValueError("PostgreSQL Windows build did not select native MSVC")
    evidence["c"] = {"id": "msvc", "version": compilers["host"]["c"].get("version"),
                     "runtime_library": "static"}
    run([*tools["meson"], "compile", "-C", str(directory), "-j", str(jobs)], directory, build_env)
    run([*tools["meson"], "install", "-C", str(directory), "--destdir", str(staged), "--no-rebuild"],
        directory, build_env)
    return arguments, evidence


def collect_licenses(source_directory, prefix):
    licenses = []
    for notice in sorted(source_directory.rglob("*")):
        if notice.is_file() and re.fullmatch(r"(?:COPYRIGHT|COPYING|LICENSE|LICENCE|NOTICE)(?:\.(?:txt|md|rst))?", notice.name, re.IGNORECASE):
            relative = notice.relative_to(source_directory)
            destination = prefix / "licenses" / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(notice, destination)
            licenses.append(relative.as_posix())
    return licenses


def prepare_windows_source(source):
    # PostgreSQL 17's pgflex replaces the child environment with FLEX_TMP_DIR
    # alone. Cygwin Flex needs PATH/SystemRoot to load its runtime and run m4.
    # Keep the already-sanitized build environment and the private temp dir.
    path = source / "src/tools/pgflex"
    original = path.read_bytes()
    before = b"env = {'FLEX_TMP_DIR': args.privatedir}\n"
    after = b"env = dict(os.environ, FLEX_TMP_DIR=args.privatedir)\n"
    if original.count(before) != 1:
        raise ValueError("unexpected PostgreSQL pgflex environment; review the Windows source patch")
    updated = original.replace(before, after)
    path.write_bytes(updated)
    return [{"file": "src/tools/pgflex", "purpose": "preserve-flex-build-environment",
             "original_sha256": hashlib.sha256(original).hexdigest(),
             "patched_sha256": hashlib.sha256(updated).hexdigest()}]


def build(plan, target, archive, output, jobs=2, windows_tools=None):
    source = validate(plan, target, jobs)
    output = Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("PostgreSQL output already exists")
    output.parent.mkdir(parents=True, exist_ok=True)
    environment = build_environment(plan, target)
    with tempfile.TemporaryDirectory(prefix=".tesl-postgres-", dir=output.parent) as temporary:
        work = Path(temporary)
        source_directory = extract_verified(source, archive, work / "source")
        configure = source_directory / "configure"
        expected = "PACKAGE_VERSION='" + source["version"] + "'"
        if expected not in configure.read_text(encoding="utf-8"):
            raise ValueError("PostgreSQL source version differs from the Nix plan")
        directory = work / "build"
        directory.mkdir()
        staged = work / "stage"
        build_tools = {}
        source_patches = []
        if target.startswith("windows-"):
            source_patches = prepare_windows_source(source_directory)
            configure_args, build_tools = build_windows(plan, source_directory, directory, staged,
                                                        environment, windows_tools, jobs)
            make_args = []
        else:
            configure_args = configure_arguments(source_directory)
            run(configure_args, directory, environment)
            make_args = make_arguments(target)
            run(["make", "-j", str(jobs), *make_args], directory, environment)
            run(["make", *make_args, "DESTDIR=" + str(staged), "install"], directory, environment)
        prefix = staged / PREFIX.lstrip("/")
        check_layout(prefix, target)
        shutil.copyfile(source_directory / "COPYRIGHT", prefix / "COPYRIGHT")
        licenses = collect_licenses(source_directory, prefix)
        if target.startswith("darwin-"):
            relocate_macos(prefix, environment)
        dependencies = audit(prefix, target, environment)
        # This invocation occurs at a different path than the compiled prefix and
        # proves libpq lookup. Full initdb/start/SQL acceptance belongs to CI.
        for command in COMMANDS:
            version = run([str(prefix / "bin" / (command + (".exe" if target.startswith("windows-") else ""))), "--version"], work, environment, capture=True)
            if not re.search(r"\b" + re.escape(source["version"]) + r"\b", version):
                raise ValueError(f"unexpected PostgreSQL version from {command}: {version.strip()}")
        metadata = {"version": 1, "component": "postgresql", "target": target,
                    "postgresql_version": source["version"], "source": source,
                    "toolchain_version": plan["toolchainVersion"],
                    "source_revision": plan["sourceRevision"],
                    "disabled_features": list(DISABLED) + ["nls"],
                    "configure": configure_args[1:], "make_variables": make_args,
                    "dependencies": dependencies, "licenses": licenses, "build_tools": build_tools,
                    "source_patches": source_patches}
        (prefix / "native-build.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        prefix.rename(output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--source-archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--windows-tools", type=Path, help="JSON command arrays for Nix-declared Windows build tools")
    args = parser.parse_args()
    try:
        output = build(json.loads(args.plan.read_text(encoding="utf-8")), args.target,
                       args.source_archive, args.output, args.jobs,
                       json.loads(args.windows_tools.read_text()) if args.windows_tools else None)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"PostgreSQL build failed: {error}\n")
    print(f"Built PostgreSQL component: {output}")


if __name__ == "__main__":
    main()

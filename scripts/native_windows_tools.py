#!/usr/bin/env python3
"""Provision Nix-pinned PostgreSQL build tools on a native Windows runner.

MSVC, its Windows SDK and a Cygwin build environment are prerequisites. Cygwin
is used only to compile/run Flex and Bison during the build; its files never enter
the Tesl payload. Every tool source archive is authenticated before execution.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from native_source import extract_verified
from native_msvc import prefer_msvc


NAMES = ("meson", "ninja", "perl", "flex", "bison")


def run(arguments, directory, environment, capture=False, timeout=1800):
    result = subprocess.run(list(map(str, arguments)), cwd=directory, env=environment,
                            check=True, text=True, capture_output=capture, timeout=timeout)
    return result.stdout.strip() if capture else None


def source_root(source, sentinel):
    if (source / sentinel).is_file():
        return source
    children = list(source.iterdir())
    if len(children) != 1 or not children[0].is_dir() or not (children[0] / sentinel).is_file():
        raise ValueError(f"tool source has no unique root containing {sentinel}")
    return children[0]


def cygwin_path(bash, value, directory, environment):
    cygpath = bash.with_name("cygpath.exe")
    if not cygpath.is_file():
        raise ValueError("Cygwin cygpath.exe is required beside bash.exe")
    return run([cygpath, "-u", "-a", value], directory, environment, capture=True, timeout=30)


def build_cygwin(name, source, build, prefix, bash, environment, jobs):
    # All supplied paths are positional arguments. Never interpolate native
    # paths, spaces or punctuation into shell code.
    paths = [cygwin_path(bash, value, build, environment) for value in (source, build, prefix)]
    script = '''set -eu
export PATH=/usr/bin:/bin
export CC=/usr/bin/gcc CXX=/usr/bin/g++
export CFLAGS=-O2 CXXFLAGS=-O2
unset CONFIG_SITE CPPFLAGS LDFLAGS LIBS MAKEFLAGS
cd "$2"
if test "$5" = bison; then
  "$1/configure" "--prefix=$3" --disable-nls --enable-relocatable
else
  "$1/configure" "--prefix=$3" --disable-nls
fi
make -j "$4"
make install
'''
    run([bash, "--noprofile", "--norc", "-c", script, "native-tool", *paths, str(jobs), name],
        build, environment)


def provision(plan, archives, output, cygwin_bash, jobs=2):
    if sys.platform != "win32":
        raise ValueError("Windows build tools must be built on native Windows")
    pins = plan.get("windowsBuildTools", {})
    if plan.get("version") != 1 or set(pins) != set(NAMES) or set(archives) != set(NAMES):
        raise ValueError("all five Windows build-tool pins and source archives are required")
    if not isinstance(jobs, int) or isinstance(jobs, bool) or jobs < 1:
        raise ValueError("jobs must be a positive integer")
    output, cygwin_bash = Path(output).absolute(), Path(cygwin_bash).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("Windows build-tool output already exists")
    if not cygwin_bash.is_file():
        raise ValueError("an explicit Cygwin bash.exe is required")
    environment = {name: value for name, value in os.environ.items()
                   if name.upper() not in {"CC", "CXX", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LIBS",
                                           "PERL5LIB", "PERL5OPT", "PERLLIB", "PERL_LOCAL_LIB_ROOT", "MAKEFLAGS"}
                   and not name.startswith("NIX_")}
    compiler = shutil.which("cl.exe", path=environment.get("PATH", ""))
    if not compiler or not shutil.which("nmake.exe", path=environment.get("PATH", "")):
        raise ValueError("native x64 MSVC cl.exe and nmake.exe must be available")
    environment = prefer_msvc(environment, compiler)
    environment.update(CC="cl.exe", CXX="cl.exe", SOURCE_DATE_EPOCH=str(plan.get("sourceDateEpoch", 0)))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".tesl-win-tools-", dir=output.parent) as temporary:
        work = Path(temporary)
        sources = {}
        sentinels = {"meson": "meson.py", "ninja": "configure.py", "perl": "win32/Makefile", "flex": "configure", "bison": "configure"}
        # Authenticate every input before running any of its build scripts.
        for name in NAMES:
            # Meson's upstream test fixtures contain symlinks. Verify them as
            # part of the full Nix tree hash, without creating Windows links.
            options = {"omit_symlinks_under": ("test cases",)} if name == "meson" else {}
            extracted = extract_verified(pins[name], archives[name], work / (name + "-source"), **options)
            sources[name] = source_root(extracted, sentinels[name])
        platform = run([cygwin_bash, "--noprofile", "--norc", "-c", "uname -s"], work,
                       environment, capture=True, timeout=30)
        if not platform.startswith("CYGWIN_NT-"):
            raise ValueError("Flex/Bison source builds require Cygwin, not MSYS/Git Bash")
        run([cygwin_bash, "--noprofile", "--norc", "-c",
             "test -x /usr/bin/gcc && test -x /usr/bin/g++ && test -x /usr/bin/make && test -x /usr/bin/m4"],
            work, environment, timeout=30)
        stage = work / "tools"
        stage.mkdir()
        meson = stage / "meson"
        meson.mkdir()
        for name in ("meson.py", "COPYING"):
            shutil.copyfile(sources["meson"] / name, meson / name)
        shutil.copytree(sources["meson"] / "mesonbuild", meson / "mesonbuild")
        # Ninja's upstream bootstrap builds itself with the active native C++ compiler.
        run([sys.executable, "configure.py", "--bootstrap"], sources["ninja"], environment)
        (stage / "ninja").mkdir()
        shutil.copyfile(sources["ninja"] / "ninja.exe", stage / "ninja/ninja.exe")
        shutil.copyfile(sources["ninja"] / "COPYING", stage / "ninja/COPYING")
        perl_prefix = stage / "perl"
        options = ["-nologo", "CCTYPE=MSVC143", "INST_TOP=" + str(perl_prefix), "INST_VER=", "INST_ARCH="]
        run(["nmake.exe", *options], sources["perl"] / "win32", environment)
        run(["nmake.exe", *options, "installbare"], sources["perl"] / "win32", environment)
        for name in ("flex", "bison"):
            build = work / (name + "-build")
            build.mkdir()
            build_cygwin(name, sources[name], build, stage / name, cygwin_bash, environment, jobs)
        # Record source hashes for generated binaries and preserve upstream
        # licenses in the build-tool artifact (separate from the runtime payload).
        for name in ("perl", "flex", "bison"):
            licenses = stage / name / "source-licenses"
            licenses.mkdir()
            for path in sources[name].iterdir():
                if path.is_file() and re.fullmatch(r"(?:COPYING|COPYRIGHT|LICENSE|Artistic)(?:\.[A-Za-z0-9_-]+)?", path.name):
                    shutil.copyfile(path, licenses / path.name)
        (stage / "native-build.json").write_text(json.dumps({
            "version": 1, "component": "windows-build-tools", "sources": pins,
            "source_revision": plan.get("sourceRevision"), "cygwin": platform,
            "runtime_payload": False,
        }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        stage.rename(output)
    commands = command_paths(output)
    try:
        for name, command in commands.items():
            arguments = ["-e", "print $^V"] if name == "perl" else ["--version"]
            version = run([*command, *arguments], output, environment, capture=True, timeout=30)
            match = re.search(r"(?<![0-9.])v?([0-9]+(?:\.[0-9]+)+)(?![0-9.])", version)
            if not match or match[1] != pins[name]["version"]:
                raise ValueError(f"built Windows {name} version differs from its source pin: {version}")
        perl_os = run([*commands["perl"], "-MConfig", "-e", "print $Config{osname}"], output,
                      environment, capture=True, timeout=30)
        if perl_os != "MSWin32":
            raise ValueError("source-built Perl is not native MSWin32 Perl")
    except (OSError, ValueError, subprocess.SubprocessError):
        shutil.rmtree(output)
        raise
    return commands


def command_paths(root):
    root = Path(root)
    return {"meson": [sys.executable, str(root / "meson/meson.py")],
            "ninja": [str(root / "ninja/ninja.exe")], "perl": [str(root / "perl/bin/perl.exe")],
            "flex": [str(root / "flex/bin/flex.exe")], "bison": [str(root / "bison/bin/bison.exe")]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--archives", type=Path, required=True, help="JSON object mapping tool names to local source archives")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cygwin-bash", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    try:
        commands = provision(json.loads(args.plan.read_text()), json.loads(args.archives.read_text()),
                             args.output, args.cygwin_bash, args.jobs)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(f"native Windows build tools failed: {error}") from error
    print(json.dumps(commands, indent=2))


if __name__ == "__main__":
    main()

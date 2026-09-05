#!/usr/bin/env python3
"""Build OCaml and Dune from verified release sources for the native compiler.

These are temporary build tools, never installed in the end-user payload. OCaml
records its installation prefix, so the returned directory must not be relocated.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

from native_sdk import host_target
from native_source import digest_bytes, extract_verified, sha256_file
import pe_audit


WINDOWS_SOURCES = {"flexdll": "flexdll.h", "winpthreads": "src/winpthread_internal.h"}
MSVC_REDISTRIBUTION = "https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution"
MSVC_RUNTIME_NAMES = re.compile(r"(?:vcruntime140(?:_1)?|msvcp140(?:_1|_2|_atomic_wait|_codecvt_ids)?|concrt140)\.dll")


def source_root(directory, sentinel):
    if (directory / sentinel).is_file():
        return directory
    children = list(directory.iterdir())
    if len(children) == 1 and children[0].is_dir() and (children[0] / sentinel).is_file():
        return children[0]
    raise ValueError(f"source has no unique root containing {sentinel}")


def build_environment(environment, plan, target, prefix):
    blocked = {"CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LIBS", "MAKEFLAGS", "MFLAGS",
               "MAKELEVEL", "CONFIG_SITE", "CPATH", "LIBRARY_PATH", "C_INCLUDE_PATH",
               "CPLUS_INCLUDE_PATH", "CAML_LD_LIBRARY_PATH", "BASH_ENV", "ENV",
               "CL", "_CL_", "LINK", "_LINK_", "FLEXLINKFLAGS"}
    result = {key: value for key, value in environment.items()
              if key not in blocked and not key.startswith(("OCAML", "OPAM", "DUNE", "NIX_",
                                                            "PKG_CONFIG", "LD_", "DYLD_", "ac_cv_"))}
    result.update(PATH=str(prefix / "bin") + os.pathsep + environment.get("PATH", ""),
                  LC_ALL="C", TZ="UTC", CONFIG_SITE="/dev/null", MAKELEVEL="0",
                  CFLAGS="-O2", SOURCE_DATE_EPOCH=str(plan.get("sourceDateEpoch", 0)),
                  OCAMLLIB=str(prefix / "lib/ocaml"), DUNE_CACHE="disabled")
    if target.startswith("darwin-"):
        candidate = next(row for row in plan["candidates"] if row["target"] == target)
        match = re.fullmatch(r"macOS ([0-9]+(?:\.[0-9]+)*)", candidate.get("baseline", ""))
        if not match:
            raise ValueError("missing or invalid macOS baseline in release plan")
        result["MACOSX_DEPLOYMENT_TARGET"] = match[1]
    if target == "windows-amd64":
        # INCLUDE/LIB/LIBPATH and the MSVC developer PATH belong to the selected
        # compiler environment. Keep them, but let OCaml choose its own C flags.
        result.pop("CFLAGS", None)
        result.update(CC="cl.exe", CXX="cl.exe")
    return result


def run(arguments, directory, environment, capture=False):
    result = subprocess.run(list(map(str, arguments)), cwd=directory, env=environment,
                            check=True, text=True, capture_output=capture, timeout=1800)
    return result.stdout.strip() if capture else None


def cygwin_path(bash, value, directory, environment):
    cygpath = bash.with_name("cygpath.exe")
    if not cygpath.is_file():
        raise ValueError("Cygwin cygpath.exe is required beside bash.exe")
    return run([cygpath, "-u", "-a", value], directory, environment, True)


def build_windows(ocaml, sources, output, bash, environment, jobs):
    """Follow OCaml's native MSVC recipe using Cygwin only as a build shell."""
    compiler = shutil.which("cl.exe", path=environment.get("PATH", ""))
    if not compiler or not Path(compiler).with_name("link.exe").is_file():
        raise ValueError("native x64 MSVC cl.exe and its link.exe are required")
    platform = run([bash, "--noprofile", "--norc", "-c", "uname -s"], ocaml, environment, True)
    if not platform.startswith("CYGWIN_NT-"):
        raise ValueError("native OCaml requires Cygwin, not MSYS/Git Bash")
    values = (ocaml, output, sources["flexdll"], sources["winpthreads"], Path(compiler).parent)
    paths = [cygwin_path(bash, value, ocaml, environment) for value in values]
    # Native paths containing spaces or shell punctuation remain positional
    # arguments. Promoting the MSVC directory prevents /usr/bin/link shadowing.
    script = '''set -eu
export PATH="$5:/usr/bin:/bin:$PATH"
export CC=cl.exe CXX=cl.exe
test -x /usr/bin/make
cd "$1"
./configure "--prefix=$2" --without-zstd \\
  --build=x86_64-pc-cygwin --host=x86_64-pc-windows \\
  "--with-flexdll=$3" "--with-winpthreads-msvc=$4"
make -j "$6" world.opt
make install
'''
    run([bash, "--noprofile", "--norc", "-c", script, "native-ocaml", *paths, str(jobs)],
        ocaml, environment)
    configure = [str(ocaml / "configure"), "--prefix=" + str(output), "--without-zstd",
                 "--build=x86_64-pc-cygwin", "--host=x86_64-pc-windows",
                 "--with-flexdll=" + str(sources["flexdll"]),
                 "--with-winpthreads-msvc=" + str(sources["winpthreads"])]
    return configure, platform


def copy_windows_licenses(sources, output):
    for name, source in sources.items():
        notices = [path for path in source.iterdir() if path.is_file()
                   and re.fullmatch(r"(?:COPYING|COPYRIGHT|LICENSE)(?:[._-][A-Za-z0-9_-]+)?", path.name, re.IGNORECASE)]
        if not notices:
            raise ValueError(f"{name} source has no license notice")
        destination = output / "licenses" / name
        destination.mkdir()
        for path in notices:
            shutil.copy2(path, destination / path.name)


def verify_runtime_license(plan, archive):
    pin = plan.get("windowsRuntimeLicense", {})
    if pin.get("hashMode") != "flat" or pin.get("hashAlgorithm") != "sha256":
        raise ValueError("a flat SHA256 Microsoft runtime license pin is required")
    archive = Path(archive)
    if archive.stat().st_size > 1024 * 1024 or sha256_file(archive) != digest_bytes(pin.get("hash", "")):
        raise ValueError("Microsoft runtime license checksum differs from release plan")
    with zipfile.ZipFile(archive) as document:
        member = document.getinfo("word/document.xml")
        if member.file_size > 1024 * 1024:
            raise ValueError("Microsoft runtime license document is too large")
        tree = ET.fromstring(document.read(member))
    namespace = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}
    text = "\n".join("".join(node.text or "" for node in paragraph.iterfind(".//w:t", namespace))
                     for paragraph in tree.iterfind(".//w:p", namespace))
    if "MICROSOFT VISUAL C++ 2015 - 2022 RUNTIME" not in text:
        raise ValueError("unexpected Microsoft runtime license document")
    return text + "\n"


def microsoft_runtime_identity(path, environment):
    # Verify the vendor signature before redistributing a build-environment DLL.
    # The file path is an environment value, never interpolated into PS code.
    command = '''$ErrorActionPreference = 'Stop'
$s = Get-AuthenticodeSignature -LiteralPath $env:TESL_MSVC_RUNTIME_FILE
if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch '(^|, )CN=Microsoft Corporation(,|$)') {
  throw 'MSVC redistributable lacks a valid Microsoft signature'
}
$v = (Get-Item -LiteralPath $env:TESL_MSVC_RUNTIME_FILE).VersionInfo
@{status='Valid'; signer=$s.SignerCertificate.Subject; version=('{0}.{1}.{2}.{3}' -f $v.FileMajorPart,$v.FileMinorPart,$v.FileBuildPart,$v.FilePrivatePart)} | ConvertTo-Json -Compress
'''
    identity = json.loads(run(["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
                              path.parent, {**environment, "TESL_MSVC_RUNTIME_FILE": str(path)}, True))
    if (identity.get("status") != "Valid" or not re.search(r"(?:^|, )CN=Microsoft Corporation(?:,|$)", identity.get("signer", ""))
            or not re.fullmatch(r"14\.[0-9]+\.[0-9]+\.[0-9]+", identity.get("version", ""))):
        raise ValueError("invalid Microsoft runtime signature/version evidence")
    return identity


def collect_windows_runtime(binary, compiler_tools, plan, environment, runtime_license):
    """Collect only final compiler PE imports from the active VS2022 CRT redist."""
    binary, compiler_tools = Path(binary), Path(compiler_tools)
    output, notices = compiler_tools / "runtime", compiler_tools / "licenses/msvc-runtime"
    if output.exists() or output.is_symlink() or notices.exists() or notices.is_symlink():
        raise ValueError("compiler runtime output already exists")
    text = verify_runtime_license(plan, runtime_license)
    if not environment.get("VSINSTALLDIR") or not environment.get("VCToolsRedistDir"):
        raise ValueError("active VSINSTALLDIR and VCToolsRedistDir are required")
    studio = Path(environment["VSINSTALLDIR"]).resolve(strict=True)
    redist = Path(environment["VCToolsRedistDir"]).resolve(strict=True)
    try:
        relative = redist.relative_to(studio / "VC/Redist/MSVC")
    except ValueError as error:
        raise ValueError("MSVC runtime directory is outside the selected Visual Studio redist") from error
    if len(relative.parts) != 1 or not re.fullmatch(r"(?:14\.[0-9]+\.[0-9]+|v143)", relative.name):
        raise ValueError("MSVC runtime directory must select one VS2022 redist version")
    directory = redist / "x64/Microsoft.VC143.CRT"
    if not directory.is_dir() or directory.resolve() != directory:
        raise ValueError("missing or redirected native x64 VC143 CRT directory")
    candidates = {}
    for path in directory.iterdir():
        name = path.name.casefold()
        if path.suffix.casefold() == ".dll":
            if name in candidates or path.is_symlink() or not path.is_file():
                raise ValueError("ambiguous or redirected MSVC runtime DLL")
            candidates[name] = path
    pending, imports, files = [binary], {}, {}
    while pending:
        path = pending.pop()
        key = path.name.casefold()
        if key in imports:
            continue
        detail = pe_audit.inspect(path)
        if path == binary and detail["is_dll"]:
            raise ValueError("compiler runtime input must be an executable")
        if path != binary and not detail["is_dll"]:
            raise ValueError("MSVC runtime dependency is not a DLL")
        needed = sorted(set(detail["imports"] + detail["delay_imports"] + detail["forwarded_imports"]))
        imports[key] = needed
        for name in needed:
            if name in pe_audit.SYSTEM_DLLS:
                continue
            if not MSVC_RUNTIME_NAMES.fullmatch(name) or name not in candidates:
                raise ValueError(f"compiler import is not a declared MSVC redistributable: {name}")
            if name not in files:
                dependency = candidates[name]
                files[name] = {"sha256": sha256_file(dependency).hex(),
                               "source": dependency.relative_to(studio).as_posix(),
                               "authenticode": microsoft_runtime_identity(dependency, environment)}
                pending.append(dependency)
    evidence = {"version": 1, "component": "compiler-runtime", "target": "windows-amd64",
                "compiler_sha256": sha256_file(binary).hex(), "files": files, "imports": imports,
                "license": plan["windowsRuntimeLicense"], "redistribution": MSVC_REDISTRIBUTION,
                "msvc_version": environment.get("VCToolsVersion"),
                "windows_sdk_version": environment.get("WindowsSDKVersion")}
    with tempfile.TemporaryDirectory(prefix=".tesl-compiler-runtime-", dir=compiler_tools) as temporary:
        stage = Path(temporary)
        (stage / "runtime").mkdir()
        (stage / "notices").mkdir()
        for name, information in files.items():
            destination = stage / "runtime" / name
            shutil.copyfile(candidates[name], destination)
            if sha256_file(destination).hex() != information["sha256"]:
                raise ValueError("MSVC runtime changed during collection")
        (stage / "runtime/native-build.json").write_text(json.dumps(evidence, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        copied_license = stage / "notices/Microsoft-Visual-C-Runtime-2015-2022.docx"
        shutil.copyfile(runtime_license, copied_license)
        if sha256_file(copied_license) != digest_bytes(plan["windowsRuntimeLicense"]["hash"]):
            raise ValueError("Microsoft runtime license changed during collection")
        (stage / "notices/LICENSE.txt").write_text(text, encoding="utf-8")
        (stage / "notices/PROVENANCE.json").write_text(json.dumps(evidence, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        (stage / "notices").rename(notices)
        try:
            (stage / "runtime").rename(output)
        except BaseException:
            shutil.rmtree(notices)
            raise
    return output


def build(plan, target, ocaml_archive, dune_archive, output, jobs=None,
          windows_archives=None, cygwin_bash=None):
    output = Path(output).absolute()
    if plan.get("version") != 1 or target not in {row["target"] for row in plan.get("candidates", [])}:
        raise ValueError("unsupported release plan or target")
    if target != host_target() or not target.startswith(("linux-", "darwin-", "windows-")):
        raise ValueError("compiler source builder requires a native host")
    windows = target == "windows-amd64"
    if target.startswith("windows-") and not windows:
        raise ValueError("unsupported native Windows compiler architecture")
    if output.exists() or output.is_symlink():
        raise ValueError("compiler tools output already exists")
    jobs = min(os.cpu_count() or 1, 4) if jobs is None else jobs
    if isinstance(jobs, bool) or not isinstance(jobs, int) or jobs < 1:
        raise ValueError("jobs must be a positive integer")
    for name in ("ocaml", "dune"):
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", plan["sources"][name].get("version", "")):
            raise ValueError(f"invalid {name} source version")
    if windows:
        pins = plan.get("windowsCompilerSources", {})
        if set(pins) != set(WINDOWS_SOURCES) or set(windows_archives or {}) != set(WINDOWS_SOURCES):
            raise ValueError("all Windows compiler source pins and archives are required")
        cygwin_bash = Path(cygwin_bash).absolute() if cygwin_bash is not None else None
        if cygwin_bash is None or not cygwin_bash.is_file():
            raise ValueError("an explicit Cygwin bash.exe is required")
    elif windows_archives is not None or cygwin_bash is not None:
        raise ValueError("Windows compiler inputs are only accepted for Windows")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".tesl-compiler-tools-", dir=output.parent) as temporary:
        work = Path(temporary)
        # Every hash is checked before any supplied build script is executed.
        ocaml = source_root(extract_verified(plan["sources"]["ocaml"], Path(ocaml_archive), work / "ocaml"), "configure")
        dune = source_root(extract_verified(plan["sources"]["dune"], Path(dune_archive), work / "dune"), "boot/bootstrap.ml")
        if (ocaml / "VERSION").read_text().splitlines()[0].strip() != plan["sources"]["ocaml"]["version"]:
            raise ValueError("OCaml source version differs from release plan")
        windows_sources = {}
        if windows:
            for name, sentinel in WINDOWS_SOURCES.items():
                extracted = extract_verified(pins[name], Path(windows_archives[name]), work / name)
                windows_sources[name] = source_root(extracted, sentinel)
        environment = build_environment(os.environ, plan, target, output)
        output.mkdir()
        try:
            # Compression is a compiler build optimization, not a Tesl feature.
            # Disabling it avoids a dependency on an unbundled zstd DLL/dylib.
            configure = [ocaml / "configure", "--prefix=" + str(output), "--without-zstd"]
            bootstrap_env = {key: value for key, value in environment.items() if key != "OCAMLLIB"}
            if windows:
                configure, cygwin_version = build_windows(ocaml, windows_sources, output,
                                                          cygwin_bash, bootstrap_env, jobs)
            else:
                run(configure, ocaml, bootstrap_env)
                run(["make", "-j", str(jobs), "world.opt"], ocaml, bootstrap_env)
                run(["make", "install"], ocaml, bootstrap_env)
            suffix = ".exe" if windows else ""
            for command in ("ocamlc", "ocamlopt"):
                if run([output / "bin" / (command + suffix), "-version"], work, environment, True) != plan["sources"]["ocaml"]["version"]:
                    raise ValueError("built OCaml version differs from release plan")
            if windows:
                for variable, expected in (("ccomp_type", "msvc"), ("architecture", "amd64"), ("os_type", "Win32")):
                    if run([output / "bin/ocamlopt.exe", "-config-var", variable], work, environment, True) != expected:
                        raise ValueError(f"built OCaml {variable} is not {expected}")
            run([output / "bin" / ("ocaml" + suffix), "boot/bootstrap.ml", "-j", str(jobs)], dune, environment)
            dune_binary = dune / "_boot/dune.exe"
            if run([dune_binary, "--version"], dune, environment, True) != plan["sources"]["dune"]["version"]:
                raise ValueError("built Dune version differs from release plan")
            shutil.copy2(dune_binary, output / "bin" / ("dune" + suffix))
            (output / "licenses").mkdir()
            shutil.copy2(ocaml / "LICENSE", output / "licenses/LICENSE")
            if (ocaml / "LICENSES").is_dir():
                shutil.copytree(ocaml / "LICENSES", output / "licenses/LICENSES")
            copy_windows_licenses(windows_sources, output)
            evidence = {"version": 1, "target": target,
                        "sources": {name: plan["sources"][name] for name in ("ocaml", "dune")},
                        "source_hashes_verified": True, "ocaml_compression": False,
                        "configure": list(map(str, configure))}
            if windows:
                evidence.update(windows_compiler_sources=pins, windows_toolchain="msvc",
                                cygwin=cygwin_version, cygwin_runtime=False)
            (output / "native-build.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        except BaseException:
            shutil.rmtree(output)
            raise
    # Dune's top-level dune.exe is a shell wrapper into _boot. Verify the copied
    # binary from an unrelated cwd after the entire source tree has disappeared.
    try:
        if run([output / "bin" / ("dune" + suffix), "--version"], output.parent,
               environment, True) != plan["sources"]["dune"]["version"]:
            raise ValueError("installed Dune version differs from release plan")
    except BaseException:
        shutil.rmtree(output)
        raise
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("plan", "ocaml-archive", "dune-archive", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--windows-archives", type=Path, help="JSON mapping flexdll and winpthreads to local source archives")
    parser.add_argument("--cygwin-bash", type=Path)
    parser.add_argument("--jobs", type=int)
    args = parser.parse_args()
    build(json.loads(args.plan.read_text(encoding="utf-8")), args.target,
          args.ocaml_archive, args.dune_archive, args.output, jobs=args.jobs,
          windows_archives=json.loads(args.windows_archives.read_text(encoding="utf-8")) if args.windows_archives else None,
          cygwin_bash=args.cygwin_bash)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Reject native payloads with undeclared runtime dependencies or newer OS needs.

This inspects binaries without executing them. It audits the executable trees,
including SDK tools and PostgreSQL libraries, rather than Go's cross-platform
binary fixtures under src/. Runtime acceptance on each baseline remains separate.
"""

import os
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess

from pe_audit import PE, audit_binary as audit_pe_binary


ELF_BASELINE_LIBRARIES = {
    "libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2", "librt.so.1",
    "libutil.so.1", "libresolv.so.2",
}
ELF_LOADERS = {
    "linux-amd64": "/lib64/ld-linux-x86-64.so.2",
    "linux-arm64": "/lib/ld-linux-aarch64.so.1",
}
EXECUTABLE_COMPONENTS = {"compiler", "go", "postgres", "initdb", "pg_ctl", "createdb", "psql"}


def _version(value):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
        raise ValueError(f"invalid system version: {value}")
    return tuple(map(int, value.split("."))) + (0,) * (4 - len(value.split(".")))


def _inside(root, path):
    try:
        path.resolve().relative_to(root)
    except (ValueError, RuntimeError) as error:
        raise ValueError(f"runtime path escapes payload: {path}") from error
    return path


def _component(root, value):
    if not isinstance(value, str) or not value or "\\" in value or ":" in value or "\0" in value:
        raise ValueError("invalid executable component path")
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError("invalid executable component path")
    return _inside(root, root / PurePosixPath(value))


def _inspect(arguments):
    try:
        return subprocess.run(arguments, check=True, text=True, capture_output=True,
                              env=dict(os.environ, LC_ALL="C", LANG="C")).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError(f"binary inspection failed: {arguments[0]}: {error}") from error


def _format(path, target):
    data = path.read_bytes()
    if b"/nix/store/" in data:
        raise ValueError(f"binary contains a Nix store reference: {path}")
    if target == "windows-amd64":
        PE(data)
        return "PE"
    if target.startswith("linux-"):
        if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01":
            raise ValueError(f"expected little-endian ELF64 binary: {path}")
        file_type, machine = struct.unpack_from("<HH", data, 16)
        if file_type not in (2, 3) or machine != {"linux-amd64": 62, "linux-arm64": 183}[target]:
            raise ValueError(f"ELF architecture or file type does not match {target}: {path}")
        return "ELF"
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError(f"expected thin little-endian Mach-O64 binary: {path}")
    cpu, _, file_type = struct.unpack_from("<III", data, 4)
    if cpu != {"darwin-amd64": 0x1000007, "darwin-arm64": 0x100000c}[target] or file_type not in (2, 6, 8):
        raise ValueError(f"Mach-O architecture or file type does not match {target}: {path}")
    return "Mach-O"


def _elf(root, path, target, baseline):
    output = _inspect(["readelf", "--wide", "-h", "-l", "-d", "-V", str(path)])
    if not re.search(r"^\s+LOAD\s", output, re.MULTILINE):
        raise ValueError(f"ELF has no auditable loadable segments: {path}")
    needed = re.findall(r"\(NEEDED\).*Shared library: \[([^\]]+)\]", output)
    interpreters = re.findall(r"Requesting program interpreter: ([^\]]+)\]", output)
    if len(interpreters) > 1 or (interpreters and interpreters[0] != ELF_LOADERS[target]):
        raise ValueError(f"non-baseline ELF interpreter: {path}: {interpreters}")
    if re.search(r"\((?:AUDIT|DEPAUDIT|FILTER|AUXILIARY)\)", output):
        raise ValueError(f"unsupported ELF dependency mechanism: {path}")
    rpaths = re.findall(r"\((?:RPATH|RUNPATH)\).*\[([^\]]*)\]", output)
    search = []
    for entry in (part for value in rpaths for part in value.split(":")):
        if not re.fullmatch(r"\$(?:ORIGIN|\{ORIGIN\})(?:/[A-Za-z0-9_.+/-]+)?", entry):
            raise ValueError(f"non-relocatable ELF library search path: {path}: {entry}")
        relative = re.sub(r"^\$(?:ORIGIN|\{ORIGIN\})/?", "", entry)
        search.append(_inside(root, path.parent / relative))
    versions = re.findall(r"Name: (GLIBC_[A-Za-z0-9_.]+)", output)
    if any(not re.fullmatch(r"GLIBC_[0-9.]+", value) for value in versions):
        raise ValueError(f"non-public GLIBC requirement: {path}")
    if any(_version(value[6:]) > _version(baseline) for value in versions):
        raise ValueError(f"ELF needs GLIBC newer than {baseline}: {path}")
    if "libc.so.6" in needed and not versions:
        raise ValueError(f"ELF libc dependency has no auditable version requirements: {path}")
    dependencies = []
    allowed = ELF_BASELINE_LIBRARIES | {Path(ELF_LOADERS[target]).name}
    for name in needed:
        if "/" in name or "\\" in name or not name:
            raise ValueError(f"non-relocatable ELF dependency: {path}: {name}")
        if name in {Path(loader).name for loader in ELF_LOADERS.values()} and name != Path(ELF_LOADERS[target]).name:
            raise ValueError(f"wrong-architecture ELF loader dependency: {path}: {name}")
        if name in allowed:
            if any((directory / name).exists() for directory in search):
                raise ValueError(f"payload shadows an OS baseline library: {path}: {name}")
            continue
        matches = [_inside(root, directory / name) for directory in search if (directory / name).is_file()]
        if not matches:
            raise ValueError(f"unbundled ELF dependency: {path}: {name}")
        dependencies.append(matches[0])
    return {"needed": needed, "interpreter": interpreters[0] if interpreters else None,
            "rpaths": rpaths, "required_glibc": sorted(set(versions))}, dependencies


def _macho(root, path, target, baseline):
    output = _inspect(["otool", "-l", str(path)])
    commands = re.split(r"\nLoad command [0-9]+\n", "\n" + output)[1:]
    rpaths, needed, versions = [], [], []
    identity = None
    for command in commands:
        kind = re.search(r"\bcmd (LC_[A-Z0-9_]+)\b", command)
        if not kind:
            raise ValueError(f"malformed Mach-O load command: {path}")
        kind = kind.group(1)
        if kind in {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB", "LC_ID_DYLIB"}:
            match = re.search(r"\n\s+name (.+) \(offset [0-9]+\)", command)
            if not match:
                raise ValueError(f"malformed Mach-O dependency: {path}")
            if kind == "LC_ID_DYLIB":
                identity = match.group(1)
            else:
                needed.append(match.group(1))
        elif kind == "LC_RPATH":
            match = re.search(r"\n\s+path (.+) \(offset [0-9]+\)", command)
            if not match:
                raise ValueError(f"malformed Mach-O search path: {path}")
            rpaths.append(match.group(1))
        elif kind == "LC_BUILD_VERSION":
            if not re.search(r"\bplatform (?:1|macos)\b", command, re.IGNORECASE):
                raise ValueError(f"non-macOS Mach-O platform: {path}")
            match = re.search(r"\bminos ([0-9.]+)", command)
            if not match:
                raise ValueError(f"missing Mach-O deployment version: {path}")
            versions.append(match.group(1))
        elif kind == "LC_VERSION_MIN_MACOSX":
            match = re.search(r"\bversion ([0-9.]+)", command)
            if not match:
                raise ValueError(f"missing Mach-O deployment version: {path}")
            versions.append(match.group(1))
        elif kind.startswith("LC_VERSION_MIN_") or kind in {"LC_DYLD_ENVIRONMENT", "LC_PREBOUND_DYLIB", "LC_LOADFVMLIB", "LC_LAZY_LOAD_DYLIB"}:
            raise ValueError(f"unsupported Mach-O runtime load command: {path}: {kind}")
    if not versions or any(_version(value) > _version(baseline) for value in versions):
        raise ValueError(f"Mach-O minimum OS is missing or exceeds macOS {baseline}: {path}")

    def relative(value):
        # @executable_path for shared libraries depends on the caller. Requiring
        # @loader_path there keeps the closure independent of the launch route.
        file_type = struct.unpack_from("<I", path.read_bytes(), 12)[0]
        tokens = ("@loader_path", "@executable_path") if file_type == 2 else ("@loader_path",)
        for token in tokens:
            if value == token or value.startswith(token + "/"):
                return _inside(root, path.parent / value[len(token):].lstrip("/"))
        raise ValueError(f"non-relocatable Mach-O path: {path}: {value}")

    search = [relative(value) for value in rpaths]
    if identity and not identity.startswith(("@rpath/", "@loader_path/")):
        raise ValueError(f"non-relocatable Mach-O library identity: {path}: {identity}")
    dependencies = []
    for name in needed:
        if name.startswith(("/usr/lib/", "/System/Library/Frameworks/")):
            if ".." in PurePosixPath(name).parts:
                raise ValueError(f"invalid system Mach-O dependency: {path}: {name}")
            continue
        if name.startswith("@rpath/"):
            matches = [_inside(root, directory / name[7:]) for directory in search
                       if (directory / name[7:]).is_file()]
        else:
            matches = [relative(name)]
        if not matches or not matches[0].is_file():
            raise ValueError(f"unbundled Mach-O dependency: {path}: {name}")
        dependencies.append(matches[0])
    return {"needed": needed, "rpaths": rpaths, "minimum_macos": versions}, dependencies


def audit(root, plan, target):
    """Return static dependency evidence, or raise ValueError on an open closure."""
    if target not in {*ELF_LOADERS, "darwin-amd64", "darwin-arm64", "windows-amd64"}:
        raise ValueError(f"payload dependency audit is not implemented for {target}")
    root = Path(root).resolve()
    try:
        candidate = next(row for row in plan["candidates"] if row["target"] == target)
        baseline = candidate["baseline"]
        if target.startswith("windows-"):
            if baseline != "Windows 11":
                raise ValueError("unsupported Windows baseline")
            system_version = None
        else:
            prefix = "glibc " if target.startswith("linux-") else "macOS "
            if not baseline.startswith(prefix):
                raise ValueError("unsupported OS baseline")
            system_version = baseline[len(prefix):]
            _version(system_version)
        components = plan["payloads"][target]["manifest"]["components"]
        executables = {name: _component(root, components[name]["path"])
                       for name in set(plan["commands"]) | EXECUTABLE_COMPONENTS}
    except (KeyError, TypeError, StopIteration) as error:
        raise ValueError("release plan lacks native payload audit metadata") from error
    pending = set(executables.values())
    executable_files = {path.resolve() for path in pending}
    # Sibling tools (gofmt, PostgreSQL helpers) also form part of the installation.
    for directory in {path.parent for path in pending}:
        if directory.is_dir():
            pending.update(path for path in directory.iterdir() if path.is_file()
                           and (not target.startswith("windows-") or path.suffix.casefold() in {".exe", ".dll"}))
    sdk = executables["go"].parent.parent
    postgres = executables["postgres"].parent.parent
    for directory in (sdk / "pkg" / "tool", postgres / "lib"):
        if directory.is_dir():
            for path in directory.rglob("*"):
                if path.is_file() and (directory == sdk / "pkg" / "tool" or re.search(r"\.(?:so(?:\.[0-9]+)*|dylib|dll)$", path.name, re.IGNORECASE)):
                    pending.add(path)
    evidence, visited = [], set()
    while pending:
        path = min(pending)
        pending.remove(path)
        # PostgreSQL ships versioned libraries with symlink aliases. Inspect and
        # record each contained file once, so downstream signing receives the
        # actual file rather than whichever alias sorts first.
        path = _inside(root, path).resolve()
        if path in visited:
            continue
        if not path.is_file():
            raise ValueError(f"missing runtime binary: {path}")
        if os.name != "nt" and path in executable_files and not os.access(path, os.X_OK):
            raise ValueError(f"runtime component is not executable: {path}")
        format_name = _format(path, target)
        if format_name == "PE":
            application_directory = postgres / "bin" if path.is_relative_to(postgres) else path.parent
            detail, dependencies = audit_pe_binary(root, path, application_directory)
            if path.suffix.casefold() == ".dll" and not detail["is_dll"]:
                raise ValueError(f"Windows DLL file is not marked as a DLL: {path}")
        else:
            detail, dependencies = (_elf if format_name == "ELF" else _macho)(root, path, target, system_version)
        if path in executable_files:
            if format_name == "PE" and detail["is_dll"]:
                raise ValueError(f"Windows component is not an executable: {path}")
            if format_name == "ELF" and detail["needed"] and not detail["interpreter"]:
                raise ValueError(f"dynamic ELF executable has no baseline interpreter: {path}")
            if format_name == "Mach-O" and struct.unpack_from("<I", path.read_bytes(), 12)[0] != 2:
                raise ValueError(f"Mach-O component is not an executable: {path}")
        evidence.append({"path": path.relative_to(root).as_posix(), "format": format_name, **detail})
        visited.add(path)
        pending.update(dependencies)
    return {"version": 1, "target": target, "baseline": baseline, "binaries": evidence}

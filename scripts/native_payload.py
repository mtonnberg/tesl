#!/usr/bin/env python3
"""Assemble and audit a native candidate payload; never publish a release.

Inputs are built by the native recipe from the Nix release plan. Every component
is required. Platform dependency audits and installed workflow checks are separate
evidence: producing an archive alone does not establish installation support.
"""

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tarfile
import tempfile
import zipfile

from module_proxy import verify as verify_module_bundle
from payload_audit import audit
from macos_distribution import sign_payload as sign_macos_payload


DIRECTORIES = {"stdlib", "templates", "doc", "go-modules", "licenses"}
PG_COMMANDS = {"postgres", "initdb", "pg_ctl", "createdb", "psql"}


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while data := stream.read(1024 * 1024):
            digest.update(data)
    return digest.hexdigest()


def relative(value):
    if (not isinstance(value, str) or not value or value.startswith("/")
            or any(char in value for char in "\\:\x00\r\n")
            or any(part in ("", ".", "..") for part in value.split("/"))):
        raise ValueError(f"unsafe payload path: {value!r}")
    return Path(value)


def payload_contract(plan, target):
    if plan.get("version") != 1 or target not in {row["target"] for row in plan["candidates"]}:
        raise ValueError("unsupported release plan or target")
    payload = plan["payloads"][target]
    manifest = payload["manifest"]
    if (manifest.get("version") != 1 or manifest.get("target") != target
            or manifest.get("toolchain_version") != plan["toolchainVersion"]
            or manifest.get("source_revision") != plan["sourceRevision"]):
        raise ValueError("payload identity differs from release plan")
    required = set(plan["commands"]) | DIRECTORIES | PG_COMMANDS | {"compiler", "go"}
    if "tesl" not in plan["commands"] or any(not re.fullmatch(r"[a-z][a-z0-9-]*", name) for name in plan["commands"]):
        raise ValueError("invalid frontend command names")
    if set(manifest["components"]) != required:
        raise ValueError("payload manifest does not contain the complete component set")
    paths = []
    for name, item in manifest["components"].items():
        paths.append(relative(item["path"]).as_posix())
        if not item.get("version") or item.get("optional"):
            raise ValueError("default payload components must have versions and be required")
        expected_version = (plan["sources"]["go"]["version"] if name == "go" else
                            plan["sources"]["postgresql"]["version"] if name in PG_COMMANDS else plan["toolchainVersion"])
        if item["version"] != expected_version:
            raise ValueError("component version differs from release plan")
    suffix = ".exe" if target.startswith("windows-") else ""
    for name in PG_COMMANDS | {"go"}:
        path = relative(manifest["components"][name]["path"])
        if len(path.parts) < 3 or path.parts[-2:] != ("bin", name + suffix):
            raise ValueError("SDK/database executable must live in its component's bin directory")
    if len({relative(manifest["components"][name]["path"]).parent for name in PG_COMMANDS}) != 1:
        raise ValueError("database tools must share one component prefix")
    if len(paths) != len(set(paths)):
        raise ValueError("overlapping payload components")
    for path in paths:
        if any(other.startswith(path + "/") for other in paths):
            raise ValueError("nested payload components")
    archive = relative(payload["archiveName"])
    if len(archive.parts) != 1:
        raise ValueError("archive name must be a filename")
    extension = ".zip" if target.startswith("windows-") else ".tar.gz"
    expected = f"tesl-{plan['toolchainVersion']}-{target}{extension}"
    if archive.name != expected:
        raise ValueError("archive name differs from payload identity")
    return manifest


def copy_tree(source, destination):
    source = source.resolve(strict=True)
    if not source.is_dir():
        raise ValueError(f"expected component directory: {source}")
    for path in source.rglob("*"):
        if path.is_symlink():
            if os.path.isabs(os.readlink(path)) or not path.resolve(strict=True).is_relative_to(source):
                raise ValueError(f"component symlink escapes its root: {path}")
        elif not path.is_file() and not path.is_dir():
            raise ValueError(f"unsupported component file: {path}")
    shutil.copytree(source, destination, symlinks=True)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")


def inventory(root):
    result = {".": {"directory": True, "mode": stat.S_IMODE(root.stat().st_mode)}}
    for path in sorted(root.rglob("*")):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[name] = {"symlink": os.readlink(path)}
        elif path.is_dir():
            result[name] = {"directory": True, "mode": stat.S_IMODE(path.stat().st_mode)}
        elif path.is_file():
            result[name] = {"sha256": file_hash(path), "bytes": path.stat().st_size,
                            "mode": stat.S_IMODE(path.stat().st_mode)}
    return result


def normalize_modes(root):
    for path in [root, *root.rglob("*")]:
        if not path.is_symlink():
            path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)


def copy_compiler_runtime(plan, compiler, source, destination):
    """Copy the explicit, hash-recorded native compiler DLL closure only."""
    source = Path(source)
    if source.is_symlink() or not source.is_dir():
        raise ValueError("compiler runtime must be an explicit directory")
    evidence = json.loads((source / "native-build.json").read_text(encoding="utf-8"))
    if (evidence.get("version") != 1 or evidence.get("component") != "compiler-runtime"
            or evidence.get("target") != "windows-amd64"
            or evidence.get("compiler_sha256") != file_hash(compiler)
            or not isinstance(plan.get("windowsRuntimeLicense"), dict)
            or evidence.get("license") != plan.get("windowsRuntimeLicense")
            or not isinstance(evidence.get("files"), dict)):
        raise ValueError("compiler runtime metadata differs from the compiler or release plan")
    files = evidence["files"]
    if {path.name for path in source.iterdir()} != set(files) | {"native-build.json"}:
        raise ValueError("compiler runtime inventory does not match its directory")
    for name, information in files.items():
        path = source / name
        if (not re.fullmatch(r"(?:vcruntime|msvcp|concrt)[0-9]+(?:_[a-z0-9]+)*\.dll", name)
                or path.is_symlink() or not path.is_file()
                or not isinstance(information, dict) or file_hash(path) != information.get("sha256")
                or not isinstance(information.get("authenticode"), dict)
                or information.get("authenticode", {}).get("status") != "Valid"):
            raise ValueError("invalid compiler runtime DLL or checksum")
    destination.mkdir(parents=True, exist_ok=True)
    for name in files:
        target = destination / name
        if target.exists() or target.is_symlink():
            raise ValueError("compiler runtime collides with an existing payload component")
        shutil.copyfile(source / name, target)
        if file_hash(target) != files[name]["sha256"]:
            raise ValueError("compiler runtime changed during assembly")
    return evidence


def assemble(plan, root, target, compiler, frontends, go_root, postgres, module_bundle,
             ocaml_license, output, compiler_runtime=None):
    output = output.absolute()
    manifest = payload_contract(plan, target)
    verify_module_bundle(plan, root, module_bundle)
    if (go_root / "VERSION").read_text().splitlines()[:1] != ["go" + plan["sources"]["go"]["version"]]:
        raise ValueError("Go SDK version differs from release plan")
    for name, prefix in (("go", go_root), ("postgresql", postgres)):
        built = json.loads((prefix / "native-build.json").read_text(encoding="utf-8"))
        if (built.get("version") != 1 or built.get("component") != name
                or built.get("target") != target or built.get("source") != plan["sources"][name]):
            raise ValueError(f"{name} build metadata differs from release plan")
    if output.exists() or output.is_symlink():
        raise FileExistsError(f"refusing to replace existing payload: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".tesl-payload-", dir=output.parent))
    components = manifest["components"]

    def location(name):
        return stage / relative(components[name]["path"])

    def copy_file(source, destination):
        if not source.is_file():
            raise ValueError(f"missing component file: {source}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        destination.chmod(0o755 if source.stat().st_mode & 0o111 else 0o644)

    try:
        suffix = ".exe" if target.startswith("windows-") else ""
        for name in plan["commands"]:
            copy_file(frontends / (name + suffix), location(name))
        copy_file(compiler, location("compiler"))
        if compiler_runtime is not None:
            if target != "windows-amd64":
                raise ValueError("compiler runtime DLLs are only accepted for Windows")
            runtime_evidence = copy_compiler_runtime(plan, compiler, compiler_runtime, location("compiler").parent)
            write_json(stage / "share/tesl/compiler-runtime.json", runtime_evidence)
        copy_tree(go_root, location("go").parent.parent)
        copy_tree(postgres, location("postgres").parent.parent)
        copy_tree(root / "tesl", location("stdlib"))
        copy_tree(root / "templates", location("templates"))
        copy_tree(root / "manual", location("doc"))
        for name in ("README.md", "INSTALL.md", "LANGUAGE-SPEC.md"):
            copy_file(root / name, location("doc") / name)
        copy_tree(module_bundle / "proxy", location("go-modules"))
        copy_tree(module_bundle / "licenses", location("licenses") / "go-modules")
        for source, name in ((root / "LICENSE", "Tesl-LICENSE"), (go_root / "LICENSE", "Go-LICENSE"),
                             (postgres / "COPYRIGHT", "PostgreSQL-COPYRIGHT")):
            copy_file(source, location("licenses") / name)
        if ocaml_license.is_dir():
            copy_tree(ocaml_license, location("licenses") / "ocaml")
        else:
            copy_file(ocaml_license, location("licenses") / "OCaml-LICENSE")
        copy_file(module_bundle / "inventory.json", stage / "share/tesl/module-inventory.json")
        write_json(stage / "share/tesl/toolchain.json", manifest)
        write_json(stage / "share/tesl/release-plan.json", plan)
        for name in components:
            path = location(name)
            if not (path.is_dir() if name in DIRECTORIES else path.is_file()):
                raise ValueError(f"missing payload component: {name}")
        normalize_modes(stage)
        evidence = audit(stage, plan, target)
        if target.startswith("darwin-"):
            evidence["macos_signatures"] = sign_macos_payload(stage, evidence, plan.get("releasePolicy", {}))
        write_json(stage / "share/tesl/payload-audit.json", evidence)
        normalize_modes(stage)
        write_json(stage / "share/tesl/payload-inventory.json", {
            "version": 1, "toolchain_version": plan["toolchainVersion"],
            "source_revision": plan["sourceRevision"], "target": target,
            "files": inventory(stage),
        })
        normalize_modes(stage)
        os.rename(stage, output)
        return evidence
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def pack(plan, target, payload, output):
    """Stable archive metadata; atomic output, with no wall-clock timestamps."""
    payload_contract(plan, target)
    if output.exists() or output.is_symlink():
        raise FileExistsError(f"refusing to replace existing archive: {output}")
    if output.name != plan["payloads"][target]["archiveName"]:
        raise ValueError("output archive does not match release plan")
    manifest = json.loads((payload / "share/tesl/toolchain.json").read_text())
    if manifest != plan["payloads"][target]["manifest"]:
        raise ValueError("installed manifest differs from archive plan")
    # A payload changed after assembly must not acquire a valid archive name.
    recorded = json.loads((payload / "share/tesl/payload-inventory.json").read_text())
    actual = inventory(payload)
    actual.pop("share/tesl/payload-inventory.json")
    if actual != recorded["files"]:
        raise ValueError("payload changed after assembly")
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".tesl-archive-", dir=output.parent)
    os.close(descriptor)
    prefix = f"tesl-{plan['toolchainVersion']}-{target}"
    epoch = plan["sourceDateEpoch"]
    try:
        entries = [payload, *sorted(payload.rglob("*"))]
        if output.name.endswith(".zip"):
            # Windows payloads have no symlinks. Permission bits are recorded for
            # inventory purposes; ZIP timestamps use their portable minimum.
            with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for path in entries:
                    if path.is_symlink():
                        raise ValueError("Windows ZIP payloads cannot contain symlinks")
                    name = prefix + ("/" + path.relative_to(payload).as_posix() if path != payload else "")
                    info = zipfile.ZipInfo(name + ("/" if path.is_dir() else ""), date_time=(1980, 1, 1, 0, 0, 0))
                    info.create_system = 3
                    info.external_attr = path.stat().st_mode << 16
                    info.compress_type = zipfile.ZIP_DEFLATED
                    archive.writestr(info, b"" if path.is_dir() else path.read_bytes())
        else:
            with open(temporary, "wb") as raw, gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                    for path in entries:
                        name = prefix + ("/" + path.relative_to(payload).as_posix() if path != payload else "")
                        info = archive.gettarinfo(str(path), arcname=name)
                        info.uid = info.gid = 0
                        info.uname = info.gname = ""
                        info.mtime = epoch
                        info.pax_headers = {}
                        if path.is_file() and not path.is_symlink():
                            with path.open("rb") as stream:
                                archive.addfile(info, stream)
                        else:
                            archive.addfile(info)
        os.rename(temporary, output)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return file_hash(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("plan", "compiler", "frontends", "go-root", "postgres", "module-bundle", "ocaml-license", "output", "archive-dir"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--compiler-runtime", type=Path)
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text(encoding="utf-8"))
    root = Path(__file__).resolve().parent.parent
    try:
        assemble(plan, root, args.target, args.compiler, args.frontends, args.go_root,
                 args.postgres, args.module_bundle, args.ocaml_license, args.output, args.compiler_runtime)
        archive = args.archive_dir / plan["payloads"][args.target]["archiveName"]
        digest = pack(plan, args.target, args.output, archive)
        checksum = archive.with_name(archive.name + ".sha256")
        with checksum.open("x", encoding="utf-8") as stream:
            stream.write(f"{digest}  {archive.name}\n")
    except (ValueError, OSError) as error:
        raise SystemExit(f"native payload failed: {error}") from error
    print(f"Assembled candidate {archive}; installed workflow acceptance is still required.")


if __name__ == "__main__":
    main()

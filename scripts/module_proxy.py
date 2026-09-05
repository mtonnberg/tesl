#!/usr/bin/env python3
"""Build a verified, deterministic offline Go proxy from the Nix-pinned locks.

Only exact versions in go.sum are served. No latest-version or VCS fallback.
The h1 algorithm and proxy layout follow https://go.dev/ref/mod#module-proxies.
The builder needs Python's standard library; installed Tesl does not need Python.
"""

import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import urllib.parse
import urllib.request
import zipfile


MAX_MODULE_BYTES = 500 << 20
LOCKS = ("runtime/go/go.mod", "runtime/go/go.sum")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def h1(files):
    """Go's directory hash: SHA-256 of sorted '<sha256>  <name>\\n' lines."""
    summary = b"".join(f"{sha256(data)}  {name}\n".encode("utf-8")
                       for name, data in sorted(files))
    return "h1:" + base64.b64encode(hashlib.sha256(summary).digest()).decode("ascii")


def escaped(value):
    return "".join("!" + char.lower() if "A" <= char <= "Z" else char for char in value)


def parse_sums(contents):
    modules = {}
    for line in contents.splitlines():
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) != 3:
            raise ValueError("malformed go.sum line")
        module, version, digest = parts
        kind = "mod" if version.endswith("/go.mod") else "zip"
        if kind == "mod":
            version = version[:-7]
        if (not re.fullmatch(r"[a-z0-9.-]+\.[a-z0-9.-]+(?:/[A-Za-z0-9._~-]+)*", module)
                or any(part in (".", "..", "") for part in module.split("/"))
                or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?(?:\+incompatible)?", version)):
            raise ValueError(f"invalid locked module/version: {module}@{version}")
        if not re.fullmatch(r"h1:[A-Za-z0-9+/]{43}=", digest):
            raise ValueError(f"unsupported checksum: {module}@{version}")
        entry = modules.setdefault((module, version), {})
        if kind in entry and entry[kind] != digest:
            raise ValueError(f"conflicting checksum: {module}@{version}")
        entry[kind] = digest
    if not modules or any("mod" not in entry for entry in modules.values()):
        raise ValueError("every locked module must have a go.mod checksum")
    return modules


def source_reader(source):
    """Read either one HTTPS proxy or an existing Go download-cache directory."""
    if source.startswith("https://"):
        def read(relative):
            url = source.rstrip("/") + "/" + urllib.parse.quote(relative, safe="/!@+")
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read(MAX_MODULE_BYTES + 1)
            if len(data) > MAX_MODULE_BYTES:
                raise ValueError("module download exceeds Go's size limit")
            return data
        return read
    if "://" in source:
        raise ValueError("source must be an HTTPS proxy or local download-cache directory")
    root = Path(source).resolve(strict=True)
    if not root.is_dir():
        raise ValueError("module source is not a directory")

    def read(relative):
        path = root / relative
        if path.stat().st_size > MAX_MODULE_BYTES:
            raise ValueError("cached module exceeds Go's size limit")
        return path.read_bytes()
    return read


def canonical_zip(data, module, version, expected):
    prefix = f"{module}@{version}/"
    files = []
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        names = set()
        if sum(info.file_size for info in archive.infolist()) > MAX_MODULE_BYTES:
            raise ValueError("expanded module exceeds Go's size limit")
        for info in archive.infolist():
            name = info.filename
            relative = name[len(prefix):].rstrip("/")
            if (not name.startswith(prefix) or any(char in name for char in "\r\n\x00\\")
                    or (relative and any(part in ("", ".", "..") for part in relative.split("/")))
                    or name in names):
                raise ValueError(f"invalid module archive member: {name}")
            names.add(name)
            files.append((name, archive.read(info)))
    if h1(files) != expected:
        raise ValueError(f"zip checksum mismatch: {module}@{version}")
    # Stored entries make bytes independent of zlib version, timestamps, member
    # order, and host platform. Distribution archives can compress the proxy.
    canonical = io.BytesIO()
    with zipfile.ZipFile(canonical, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, content in sorted(files):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = (0o40755 if name.endswith("/") else 0o100644) << 16
            archive.writestr(info, content)
    licenses = [(name[len(prefix):], content) for name, content in files
                if re.fullmatch(r"(LICEN[CS]E|COPYING|NOTICE|PATENTS)([.-].*)?", name.rsplit("/", 1)[-1], re.IGNORECASE)]
    return canonical.getvalue(), sorted(licenses)


def build(plan, root, output, read):
    if plan.get("version") != 1 or set(plan.get("moduleInputs", [])) != set(LOCKS):
        raise ValueError("unsupported release module inputs")
    locks = {name: (root / name).read_bytes() for name in LOCKS}
    hashes = {name: sha256(data) for name, data in locks.items()}
    if hashes != plan.get("moduleInputHashes"):
        raise ValueError("module lock files differ from the Nix release plan")
    modules = parse_sums(locks[LOCKS[1]].decode("utf-8"))
    if output.exists() or output.is_symlink():
        raise FileExistsError(f"refusing to replace existing bundle: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".tesl-modules-", dir=output.parent))
    inventory = {"version": 1, "toolchain_version": plan["toolchainVersion"],
                 "source_revision": plan["sourceRevision"], "module_inputs": hashes,
                 "modules": [], "files": {}}

    def write(relative, data):
        path = stage / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o644)
        inventory["files"][relative] = {"sha256": sha256(data), "bytes": len(data)}

    try:
        for (module, version), sums in sorted(modules.items()):
            stem = f"{escaped(module)}/@v/{escaped(version)}"
            mod = read(stem + ".mod")
            if h1([("go.mod", mod)]) != sums["mod"]:
                raise ValueError(f"go.mod checksum mismatch: {module}@{version}")
            write("proxy/" + stem + ".mod", mod)
            # Time is optional in GOPROXY .info. Omitting it avoids mutable
            # provider metadata and inventing an upstream commit timestamp.
            write("proxy/" + stem + ".info", (json.dumps({"Version": version}) + "\n").encode())
            item = {"path": module, "version": version, "checksums": sums, "licenses": []}
            if "zip" in sums:
                archive, licenses = canonical_zip(read(stem + ".zip"), module, version, sums["zip"])
                write("proxy/" + stem + ".zip", archive)
                for name, content in licenses:
                    path = f"licenses/{escaped(module)}@{escaped(version)}/{name}"
                    write(path, content)
                    item["licenses"].append(path)
            inventory["modules"].append(item)
        (stage / "inventory.json").write_text(json.dumps(inventory, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
        # No cache locks, ziphash shortcuts, extracted sources, or unrelated
        # modules are copied. Failed builds never expose a partial destination.
        os.rename(stage, output)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    return inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source", default="https://proxy.golang.org")
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text(encoding="utf-8"))
    root = Path(__file__).resolve().parent.parent
    try:
        inventory = build(plan, root, args.output, source_reader(args.source))
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        raise SystemExit(f"module bundle failed: {error}") from error
    size = sum(item["bytes"] for item in inventory["files"].values())
    print(f"Bundled {len(inventory['modules'])} locked module versions ({size} bytes)")


if __name__ == "__main__":
    main()

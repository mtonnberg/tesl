"""Verify and extract the source formats exported by the Nix release plan."""

import base64
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import struct
import tarfile
import tempfile


MAX_SOURCE_BYTES = 1024 * 1024 * 1024


def digest_bytes(value):
    if not isinstance(value, str) or not value.startswith("sha256-"):
        raise ValueError("source hash must be a sha256 SRI hash")
    try:
        digest = base64.b64decode(value[7:], validate=True)
    except ValueError as error:
        raise ValueError("invalid source hash") from error
    if len(digest) != 32:
        raise ValueError("invalid source hash length")
    return digest


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while data := stream.read(1024 * 1024):
            digest.update(data)
    return digest.digest()


def nar_hash(root):
    """Hash a source tree as Nix's canonical archive, without requiring Nix.

    NAR strings have an unsigned little-endian length and zero padding to eight
    bytes. Directory entries sort by filename bytes; only owner executable mode
    affects regular files. Our extraction policy excludes links/special files.
    """
    digest = hashlib.sha256()

    def string(data):
        if isinstance(data, str):
            data = data.encode("utf-8")
        digest.update(struct.pack("<Q", len(data)))
        digest.update(data)
        digest.update(b"\0" * (-len(data) % 8))

    def node(path):
        mode = path.lstat().st_mode
        string("(")
        string("type")
        if stat.S_ISDIR(mode):
            string("directory")
            for child in sorted(path.iterdir(), key=lambda child: os.fsencode(child.name)):
                for item in ["entry", "(", "name", os.fsencode(child.name), "node"]:
                    string(item)
                node(child)
                string(")")
        elif stat.S_ISREG(mode):
            string("regular")
            if mode & stat.S_IXUSR:
                string("executable")
                string("")
            string("contents")
            size = path.stat().st_size
            digest.update(struct.pack("<Q", size))
            with path.open("rb") as source:
                while data := source.read(1024 * 1024):
                    digest.update(data)
            digest.update(b"\0" * (-size % 8))
        else:
            raise ValueError(f"unsupported source file type: {path}")
        string(")")

    string("nix-archive-1")
    node(Path(root))
    return digest.digest()


def extract_verified(source, archive, output):
    """Return an extracted source directory, atomically published at output.

    source is plan['sources'][component], archive is a local tar file, and output
    must not exist. Recursive hashes authenticate a stripRoot-normalized NAR;
    flat hashes authenticate the original archive bytes. No source code executes
    before the applicable hash has been verified. Links and special files are
    rejected to keep extraction and later source traversal inside this directory.
    """
    archive, output = Path(archive), Path(output)
    expected = digest_bytes(source.get("hash"))
    if source.get("hashAlgorithm") != "sha256":
        raise ValueError("unsupported source hash algorithm")
    if source.get("hashMode") not in ("flat", "recursive"):
        raise ValueError("unsupported or missing source hash mode")
    if not isinstance(source.get("stripRoot"), bool):
        raise ValueError("source stripRoot must be explicit")
    if output.exists() or output.is_symlink():
        raise ValueError("source output already exists")
    if archive.stat().st_size > MAX_SOURCE_BYTES:
        raise ValueError("source archive is too large")
    if source["hashMode"] == "flat":
        if sha256_file(archive) != expected:
            raise ValueError("source archive checksum mismatch")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".tesl-source-", dir=output.parent) as temporary:
        unpacked = Path(temporary) / "unpacked"
        unpacked.mkdir()
        seen, total = set(), 0
        with tarfile.open(archive, "r:*") as stream:
            for member in stream:
                name = member.name.rstrip("/")
                path = PurePosixPath(name)
                if (not name or path.is_absolute() or "\\" in name or
                        any(part in ("", ".", "..") for part in name.split("/")) or
                        name in seen or not (member.isdir() or member.isfile())):
                    raise ValueError(f"unsafe or duplicate source archive member: {member.name}")
                seen.add(name)
                total += member.size
                if total > MAX_SOURCE_BYTES:
                    raise ValueError("expanded source archive is too large")
                destination = unpacked.joinpath(*path.parts)
                if member.isdir():
                    destination.mkdir(parents=True, exist_ok=True)
                else:
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with stream.extractfile(member) as content, destination.open("xb") as target:
                        shutil.copyfileobj(content, target)
                    destination.chmod(0o755 if member.mode & stat.S_IXUSR else 0o644)
        children = list(unpacked.iterdir())
        if not children:
            raise ValueError("empty source archive")
        if source["stripRoot"]:
            if len(children) != 1 or not children[0].is_dir():
                raise ValueError("source archive must have a single root directory")
            unpacked = children[0]
        if source["hashMode"] == "recursive" and nar_hash(unpacked) != expected:
            raise ValueError("source tree checksum mismatch")
        unpacked.rename(output)
    return output

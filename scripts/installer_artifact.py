"""Append a verified portable ZIP to the native Windows installer executable.

The outer SHA-256 is published with the release. The embedded digest detects
payload damage; it is not an Authenticode signature or publisher identity.
"""

import hashlib
import os
from pathlib import Path
import shutil
import struct
import tempfile
import zipfile


MAGIC = b"TESL-INSTALL-V1\0"
FOOTER = struct.Struct("<16sQQ32s")


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.digest()


def bundle(installer, archive, expected_sha256, output):
    installer, archive, output = map(Path, (installer, archive, output))
    if output.exists() or output.is_symlink():
        raise ValueError("setup executable output already exists")
    with installer.open("rb") as source:
        if source.read(2) != b"MZ":
            raise ValueError("setup bootstrap must be a Windows executable")
        if installer.stat().st_size >= FOOTER.size:
            source.seek(-FOOTER.size, os.SEEK_END)
            if source.read(len(MAGIC)) == MAGIC:
                raise ValueError("setup bootstrap already has an embedded archive")
    digest = sha256(archive)
    if digest.hex() != expected_sha256:
        raise ValueError("portable ZIP checksum differs from the tested artifact")
    if not zipfile.is_zipfile(archive):
        raise ValueError("setup payload must be a portable ZIP")
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".tesl-setup-", dir=output.parent)
    temporary = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as destination:
            with installer.open("rb") as source:
                shutil.copyfileobj(source, destination)
            offset = destination.tell()
            embedded_hash = hashlib.sha256()
            with archive.open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    destination.write(chunk)
                    embedded_hash.update(chunk)
            length = destination.tell() - offset
            if embedded_hash.digest() != digest:
                raise ValueError("portable ZIP changed while assembling setup executable")
            destination.write(FOOTER.pack(MAGIC, offset, length, digest))
            destination.flush()
            os.fsync(destination.fileno())
        temporary.chmod(0o755)
        temporary.rename(output)
    finally:
        temporary.unlink(missing_ok=True)
    return sha256(output).hex()

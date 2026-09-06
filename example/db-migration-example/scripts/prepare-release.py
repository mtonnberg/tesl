#!/usr/bin/env python3
"""Restore saved target inputs; never regenerate a seal or change its provenance."""
import hashlib
import json
from pathlib import Path
import shutil
import sys

app = Path(__file__).resolve().parents[1]
if len(sys.argv) != 3 or sys.argv[1] not in [str(n) for n in range(1, 8)]:
    sys.exit("usage: prepare-release.py REVISION(1..7) NEW_OUTPUT_DIRECTORY")
revision = int(sys.argv[1])
output = Path(sys.argv[2]).absolute()
if output.exists() or output.is_symlink():
    sys.exit("output must be a new directory; existing paths are never overwritten")
archive = json.loads((app / "releases" / f"v{revision}.json").read_text())
entry = (app / "todo-app.tesl").read_bytes()
if hashlib.sha256(entry).hexdigest() != archive["appSha256"]:
    sys.exit("todo-app.tesl changed: release replay requires the reviewed unchanged app; compile your current source directly for new app releases")
if archive["format"] != 1 or archive["revision"] != revision:
    sys.exit("invalid release archive")
for relative in archive["files"]:
    if Path(relative).is_absolute() or ".." in Path(relative).parts:
        sys.exit("invalid archived path")
output.mkdir(parents=True)
source = output / "source"
source.mkdir()
(source / "todo-app.tesl").write_bytes(entry)
shutil.copyfile(app / "tesl.toml", source / "tesl.toml")
for previous in range(1, revision):
    target = source / "schema" / "todo" / f"v{previous}"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(app / "schema" / "todo" / f"v{previous}.tesl", target.with_suffix(".tesl"))
    shutil.copytree(app / "schema" / "todo" / f"v{previous}", target)
    if previous > 1:
        destination = source / "migrations" / "todo" / f"v{previous}.tesl"
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(app / "migrations" / "todo" / f"v{previous}.tesl", destination)
for relative, content in archive["files"].items():
    destination = source / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(content)
(output / "release.json").write_text(json.dumps({
    "revision": revision,
    "description": archive["description"],
    "appSha256": archive["appSha256"],
    "sourceSha256": {str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in sorted(source.rglob("*")) if p.is_file()},
}, indent=2) + "\n")
print(output)

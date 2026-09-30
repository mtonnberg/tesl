#!/usr/bin/env python3
"""Check teaching failures, then emit valid starters and repairs for the Go gate."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def check(compiler, source, expected):
    result = subprocess.run([compiler, "agent-context", str(source)],
                            capture_output=True, text=True, timeout=60)
    snapshot = json.loads(result.stdout)
    errors = [d["code"] for d in snapshot["diagnostics"] if d["severity"] == "error"]
    if errors != expected or snapshot["ok"] != (not expected) or result.returncode != bool(expected):
        raise ValueError(f"{source}: expected errors {expected}; got {result.stdout}{result.stderr}")


def repair_source(source, example):
    repair = example.get("repair")
    if not repair:
        if example["errors"]:
            raise ValueError(f"{example['file']}: a rejected starter needs a buildable repair")
        return None
    before, after = repair
    if not before or source.count(before) != 1:
        raise ValueError(f"{example['file']}: repair target must occur exactly once")
    return source.replace(before, after)


def main(compiler, source_path, output_prefix):
    source = Path(source_path)
    root = Path(__file__).resolve().parent.parent
    examples = json.loads((root / "playground/examples.json").read_text())
    matches = [example for example in examples if example["file"] == source.name]
    if len(matches) != 1:
        raise ValueError(f"{source}: expected exactly one playground manifest entry")
    example = matches[0]
    check(compiler, source, example["errors"])
    repaired = repair_source(source.read_text(), example)

    def emit(path, variant):
        subprocess.run([compiler, "--backend", "go", str(path), "--out", output_prefix + variant],
                       check=True, stdout=subprocess.DEVNULL, timeout=60)

    if not example["errors"]:
        emit(source, "-starter")
    if repaired is not None:
        with tempfile.TemporaryDirectory(prefix="tesl-corpus-repair-") as directory:
            target = Path(directory) / source.name
            target.write_text(repaired)
            check(compiler, target, [])
            emit(target, "-repair")


if __name__ == "__main__":
    main(*sys.argv[1:])

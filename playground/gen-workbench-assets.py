#!/usr/bin/env python3
"""Materialize official examples; no duplicate hand-maintained source strings."""
import json, pathlib, shutil, sys
repo, out = map(pathlib.Path, sys.argv[1:])
examples = json.loads((repo / "playground/examples.json").read_text())
(out / "examples").mkdir(exist_ok=True)
items = []
for example in examples:
    source = repo / "example/playground" / example["file"]
    items.append({"name": example["name"], "src": source.read_text(), "id": source.stem})
    shutil.copyfile(source, out / "examples" / example["file"])
    # Keep previously shared example links working after the customer rename.
    if source.stem in ("customer-invoice", "customer-invoice-unchecked"):
        shutil.copyfile(source, out / "examples" / example["file"].replace("customer", "workspace"))
(out / "examples.js").write_text("window.TESL_EXAMPLES = " + json.dumps(items, ensure_ascii=False) + ";\n")

defaults = [i for i, example in enumerate(examples) if example.get("default")]
assert len(defaults) == 1, "Exactly one default example is required"
with (out / "examples.js").open("a") as script:
    script.write("window.TESL_DEFAULT_EXAMPLE = " + str(defaults[0]) + ";\n")

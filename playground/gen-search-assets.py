#!/usr/bin/env python3
"""Build identity and self-contained examples. No model, network or remote data.

Every source checks with BOTH emitted browser and native compilers before it is
linked. Source hashes identify the example; SRI binds assets to this build. A
source fragment still opens against the current deployed checker, not history.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    repo, out = (Path(p).resolve() for p in sys.argv[1:])
    compiler = repo / "compiler/_build/default/bin/main.exe"
    env = {**os.environ, "TESL_REPO_ROOT": str(repo)}
    catalog = json.loads(subprocess.check_output([compiler, "--catalog-json"], env=env))
    names = {e["name"] for e in catalog["entries"]}
    manifest = json.loads((repo / "playground/search-examples.json").read_text())
    assert manifest["version"] == 1
    examples = []
    for row in manifest["examples"]:
        path = (repo / row["path"]).resolve()
        if not path.is_relative_to(repo) or path.suffix != ".tesl":
            raise ValueError(f"Invalid example path: {row['path']}")
        source = path.read_text()
        context = json.loads(subprocess.check_output([compiler, "agent-context", path], env=env))
        if not context["ok"] or context["proof_obligations"]:
            raise ValueError(f"Example does not check: {row['path']}")
        if not set(row["symbols"]) <= names:
            raise ValueError(f"Example links an unknown catalog name: {row['path']}")
        encoded = base64.urlsafe_b64encode(source.encode()).decode().rstrip("=")
        examples.append({**row, "source": source,
                         "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
                         "fragment": "s" + encoded})
    browser_check = r"""
globalThis.window = globalThis;
require(process.argv[1]); require(process.argv[2]);
const data = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
if (JSON.parse(teslCatalog()).catalog_id !== data.catalog_id) throw Error('Native/browser catalog mismatch');
for (const example of data.examples) {
  const errors = JSON.parse(teslCheck(example.source)).diagnostics.filter(d => d.severity === 'error');
  if (errors.length) throw Error(example.path + ': ' + JSON.stringify(errors));
}
"""
    subprocess.run(["node", "-e", browser_check, out / "tesl_playground.js", out / "tesl_search.js"],
                   input=json.dumps({"catalog_id": catalog["catalog_id"], "examples": examples}),
                   text=True, check=True)
    # Source is carried once in the share fragment; the presentation needs no
    # second copy of the entire lesson text.
    for example in examples:
        del example["source"]
    examples_json = json.dumps({"version": 1, "catalog_id": catalog["catalog_id"], "examples": examples},
                               ensure_ascii=True, separators=(",", ":")) + "\n"
    (out / "search-examples.json").write_text(examples_json)
    assets = {}
    for name in ["tesl_playground.js", "tesl_search.js", "search-examples.json", "playground-elm.js", "monaco.js", "monaco.css", "monaco-worker.js"]:
        data = (out / name).read_bytes()
        digest = hashlib.sha256(data).digest()
        assets[name] = {"sha256": digest.hex(), "integrity": "sha256-" + base64.b64encode(digest).decode(), "bytes": len(data)}
    identity = {
        "version": 1, "catalog_id": catalog["catalog_id"], "assets": assets,
        "source_revision": subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"], text=True).strip(),
        "source_dirty": bool(subprocess.check_output(["git", "-C", repo, "status", "--porcelain"], text=True)),
    }
    (out / "playground-build.js").write_text("window.TESL_BUILD = " + json.dumps(identity, separators=(",", ":")) + ";\n")
    print(f"    search: {len(catalog['entries'])} catalog entries, {len(examples)} checked examples; {catalog['catalog_id']}")


if __name__ == "__main__":
    main()

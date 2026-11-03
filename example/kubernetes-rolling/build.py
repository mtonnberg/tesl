#!/usr/bin/env python3
"""Build three frozen releases; requires the repository's Nix toolchain, no cluster."""
import argparse
import json
import os
from pathlib import Path
import re
import runpy
import shutil

DEMO = Path(__file__).resolve().parent
ROOT = DEMO.parents[1]
COMMON = runpy.run_path(str(DEMO.parent / "db-three-upgrades/run.py"))
command, preview = COMMON["command"], COMMON["apply_preview"]


def build(output, compiler):
    env = dict(os.environ, TESL_REPO_ROOT=str(ROOT), CGO_ENABLED="0")
    image_env = dict(env, GOOS="linux", GOARCH=command(["go", "env", "GOHOSTARCH"], env=env).strip())
    source = output / "source"
    shutil.copytree(DEMO / "schema", source / "schema")
    shutil.copyfile(DEMO / "tesl.toml", source / "tesl.toml")
    shutil.copyfile(DEMO / "app.tesl", source / "app.tesl")
    entry, current = source / "app.tesl", source / "schema/demo/v-current.tesl"
    for version in (1, 2, 3):
        if version > 1:
            preview(compiler, entry, env, "generate", "--new-revision")
            shutil.copyfile(DEMO / f"versions/v{version}.tesl", current)
            edge = source / f"migrations/demo/v{version}.tesl"
            header = edge.read_text().split("module ", 1)[0]
            if version == 2:
                body = '''module Schema.Demo.Migrate.V2 exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..)]
import Schema.Demo.V1
import Schema.Demo.VCurrent
migration = Migration {
  from: Schema.Demo.V1
  to: Schema.Demo.VCurrent
  same: []
  entities: { Note: Derived [Rename title headline] }
}
'''
            else:
                (source / "migrations/demo/convert3.tesl").write_text('''module Schema.Demo.Migrate.Convert3 exposing [convert, fixture]
import Tesl.Migration exposing [Migrated(..)]
import Schema.Demo.V2
import Schema.Demo.VCurrent
fn convert(old: Schema.Demo.V2.Delivery) -> Migrated Schema.Demo.VCurrent.Delivery =
  Row (Schema.Demo.VCurrent.Delivery { id: old.id, message: old.text, priority: 1 })
fn fixture() -> Schema.Demo.V2.Delivery = Schema.Demo.V2.Delivery { id: "fixture", text: "kept" }
''')
                body = '''module Schema.Demo.Migrate.V3 exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..)]
import Schema.Demo.V2
import Schema.Demo.VCurrent
import Schema.Demo.Migrate.Convert3
migration = Migration {
  from: Schema.Demo.V2
  to: Schema.Demo.VCurrent
  same: []
  entities: {}
  jobs: { Delivery: Migrate Schema.Demo.Migrate.Convert3.convert }
  fixtures: [Schema.Demo.Migrate.Convert3.fixture]
}
'''
                updated, count = re.subn(r"enqueue Delivery\s*\{\s*id:\s*id[,\s]+text:\s*id\s*\}",
                                         "enqueue Delivery { id: id, message: id, priority: 1 }", entry.read_text())
                if count != 1:
                    raise RuntimeError("the checked queue enqueue example changed; update the V3 build recipe")
                entry.write_text(updated)
            edge.write_text(header + body)
            preview(compiler, entry, env, "generate")
            if version == 2:
                preview(compiler, entry, env, "contract", "--version", "2")
        for path in sorted(source.rglob("*.tesl")):
            context = json.loads(command([compiler, "agent-context", path], env=env))
            if not context["ok"]:
                raise RuntimeError(json.dumps(context))
        release = output / f"v{version}"
        release.mkdir()
        shutil.copytree(source, release / "source")
        command([compiler, "--backend", "go", entry, "--out", release / "go"], env=env)
        command(["go", "test", "./..."], cwd=release / "go", env=env, timeout=180)
        command(["go", "build", "-trimpath", "-o", release / "app", "./cmd/app"], cwd=release / "go", env=image_env, timeout=180)
        print(f"Built V{version}: {release / 'app'}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, default=ROOT / "compiler/_build/default/bin/main.exe")
    args = parser.parse_args()
    output = args.output.absolute()
    if output.exists():
        parser.error("choose a new output directory")
    output.mkdir(parents=True)
    build(output, args.compiler.absolute())


if __name__ == "__main__":
    main()

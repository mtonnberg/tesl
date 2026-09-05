#!/usr/bin/env python3
"""Build OCaml and Dune from verified release sources for the native compiler.

These are temporary build tools, never installed in the end-user payload. OCaml
records its installation prefix, so the returned directory must not be relocated.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from native_sdk import host_target
from native_source import extract_verified


def source_root(directory, sentinel):
    if (directory / sentinel).is_file():
        return directory
    children = list(directory.iterdir())
    if len(children) == 1 and children[0].is_dir() and (children[0] / sentinel).is_file():
        return children[0]
    raise ValueError(f"source has no unique root containing {sentinel}")


def build_environment(environment, plan, target, prefix):
    blocked = {"CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LIBS", "MAKEFLAGS", "MFLAGS",
               "MAKELEVEL", "CONFIG_SITE", "CPATH", "LIBRARY_PATH", "C_INCLUDE_PATH",
               "CPLUS_INCLUDE_PATH", "CAML_LD_LIBRARY_PATH"}
    result = {key: value for key, value in environment.items()
              if key not in blocked and not key.startswith(("OCAML", "OPAM", "DUNE", "NIX_",
                                                            "PKG_CONFIG", "LD_", "DYLD_", "ac_cv_"))}
    result.update(PATH=str(prefix / "bin") + os.pathsep + environment.get("PATH", ""),
                  LC_ALL="C", TZ="UTC", CONFIG_SITE="/dev/null", MAKELEVEL="0",
                  CFLAGS="-O2", SOURCE_DATE_EPOCH=str(plan.get("sourceDateEpoch", 0)),
                  OCAMLLIB=str(prefix / "lib/ocaml"), DUNE_CACHE="disabled")
    if target.startswith("darwin-"):
        candidate = next(row for row in plan["candidates"] if row["target"] == target)
        match = re.fullmatch(r"macOS ([0-9]+(?:\.[0-9]+)*)", candidate.get("baseline", ""))
        if not match:
            raise ValueError("missing or invalid macOS baseline in release plan")
        result["MACOSX_DEPLOYMENT_TARGET"] = match[1]
    return result


def run(arguments, directory, environment, capture=False):
    result = subprocess.run(list(map(str, arguments)), cwd=directory, env=environment,
                            check=True, text=True, capture_output=capture, timeout=1800)
    return result.stdout.strip() if capture else None


def build(plan, target, ocaml_archive, dune_archive, output, jobs=None):
    output = Path(output).absolute()
    if plan.get("version") != 1 or target not in {row["target"] for row in plan.get("candidates", [])}:
        raise ValueError("unsupported release plan or target")
    if target != host_target() or not target.startswith(("linux-", "darwin-")):
        raise ValueError("compiler source builder requires a native Unix host")
    if output.exists() or output.is_symlink():
        raise ValueError("compiler tools output already exists")
    jobs = min(os.cpu_count() or 1, 4) if jobs is None else jobs
    if isinstance(jobs, bool) or not isinstance(jobs, int) or jobs < 1:
        raise ValueError("jobs must be a positive integer")
    for name in ("ocaml", "dune"):
        if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", plan["sources"][name].get("version", "")):
            raise ValueError(f"invalid {name} source version")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".tesl-compiler-tools-", dir=output.parent) as temporary:
        work = Path(temporary)
        # Both hashes are checked before any supplied build script is executed.
        ocaml = source_root(extract_verified(plan["sources"]["ocaml"], Path(ocaml_archive), work / "ocaml"), "configure")
        dune = source_root(extract_verified(plan["sources"]["dune"], Path(dune_archive), work / "dune"), "boot/bootstrap.ml")
        if (ocaml / "VERSION").read_text().splitlines()[0].strip() != plan["sources"]["ocaml"]["version"]:
            raise ValueError("OCaml source version differs from release plan")
        environment = build_environment(os.environ, plan, target, output)
        output.mkdir()
        try:
            # Compression is a compiler build optimization, not a Tesl feature.
            # Disabling it avoids a dependency on an unbundled zstd DLL/dylib.
            configure = [ocaml / "configure", "--prefix=" + str(output), "--without-zstd"]
            bootstrap_env = {key: value for key, value in environment.items() if key != "OCAMLLIB"}
            run(configure, ocaml, bootstrap_env)
            run(["make", "-j", str(jobs), "world.opt"], ocaml, bootstrap_env)
            run(["make", "install"], ocaml, bootstrap_env)
            for command in ("ocamlc", "ocamlopt"):
                if run([output / "bin" / command, "-version"], work, environment, True) != plan["sources"]["ocaml"]["version"]:
                    raise ValueError("built OCaml version differs from release plan")
            run([output / "bin/ocaml", "boot/bootstrap.ml", "-j", str(jobs)], dune, environment)
            if run([dune / "dune.exe", "--version"], dune, environment, True) != plan["sources"]["dune"]["version"]:
                raise ValueError("built Dune version differs from release plan")
            shutil.copy2(dune / "dune.exe", output / "bin/dune")
            (output / "licenses").mkdir()
            shutil.copy2(ocaml / "LICENSE", output / "licenses/LICENSE")
            if (ocaml / "LICENSES").is_dir():
                shutil.copytree(ocaml / "LICENSES", output / "licenses/LICENSES")
            evidence = {"version": 1, "target": target,
                        "sources": {name: plan["sources"][name] for name in ("ocaml", "dune")},
                        "source_hashes_verified": True, "ocaml_compression": False,
                        "configure": list(map(str, configure))}
            (output / "native-build.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        except BaseException:
            shutil.rmtree(output)
            raise
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("plan", "ocaml-archive", "dune-archive", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()
    build(json.loads(args.plan.read_text(encoding="utf-8")), args.target,
          args.ocaml_archive, args.dune_archive, args.output)


if __name__ == "__main__":
    main()

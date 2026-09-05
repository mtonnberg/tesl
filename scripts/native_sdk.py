#!/usr/bin/env python3
"""Build the native Go SDK from the Nix-pinned upstream source archive.

The runner's Go is only a bootstrap tool. Using its installed tree as a payload
could carry downstream patches or absolute runtime paths into the distribution.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

from native_source import extract_verified


def host_target():
    system = {"Linux": "linux", "Darwin": "darwin", "Windows": "windows"}.get(platform.system())
    arch = {"x86_64": "amd64", "AMD64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine())
    return f"{system}-{arch}"


def build_environment(environment, target, bootstrap, work):
    # Clear inherited compiler/build flags, including Go's patch-time loader and
    # external-link defaults. Pin build caches to the disposable build directory.
    result = {key: value for key, value in environment.items()
              if not key.upper().startswith(("GO", "CGO_", "CC", "CXX", "PKG_CONFIG"))}
    system, arch = target.split("-")
    result.update(GOOS=system, GOARCH=arch, GOHOSTOS=system, GOHOSTARCH=arch,
                  GOTOOLCHAIN="local", GOENV="off", GOWORK="off", GOPROXY="off", GOSUMDB="off",
                  CGO_ENABLED="0", GO_EXTLINK_ENABLED="0", GOROOT_BOOTSTRAP=str(bootstrap),
                  GOCACHE=str(work / "cache"), GOMODCACHE=str(work / "modules"),
                  GOMAXPROCS=str(min(os.cpu_count() or 1, 4)))
    return result


def build(plan, target, archive, bootstrap, output):
    archive, output = Path(archive).absolute(), Path(output).absolute()
    if plan.get("version") != 1 or target not in {row["target"] for row in plan["candidates"]}:
        raise ValueError("unsupported release plan or target")
    if target != host_target():
        raise ValueError("SDK builder requires the native target host")
    if output.exists() or output.is_symlink():
        raise ValueError("SDK output already exists")
    bootstrap = bootstrap.resolve(strict=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".tesl-sdk-", dir=output.parent) as temporary:
        work = Path(temporary)
        source = extract_verified(plan["sources"]["go"], archive, work / "source")
        # Upstream flat Go tarballs contain one go/ root. Recursive exports may
        # already strip it; both must have the exact release VERSION file.
        sdk = source if (source / "VERSION").is_file() else source / "go"
        version = "go" + plan["sources"]["go"]["version"]
        if (sdk / "VERSION").read_text().splitlines()[0] != version:
            raise ValueError("Go source version differs from release plan")
        environment = build_environment(os.environ, target, bootstrap, work)
        suffix = ".exe" if target.startswith("windows-") else ""
        reported = subprocess.run([str(bootstrap / "bin" / ("go" + suffix)), "env", "GOVERSION"],
                                  check=True, text=True, capture_output=True, timeout=30, env=environment).stdout.strip()
        if reported != version:
            raise ValueError("bootstrap Go version differs from release plan")
        command = ["cmd.exe", "/c", "make.bat"] if suffix else ["bash", "make.bash"]
        subprocess.run(command, cwd=sdk / "src", env=environment, check=True, timeout=1200)
        executable = sdk / "bin" / ("go" + suffix)
        reported = subprocess.run([str(executable), "version"], env=environment, check=True,
                                  text=True, capture_output=True, timeout=30).stdout.strip()
        if reported != f"go version {version} {target.replace('-', '/')}":
            raise ValueError("built SDK does not match requested version/target")
        for name in ("pkg/bootstrap", "pkg/obj"):
            shutil.rmtree(sdk / name, ignore_errors=True)
        (sdk / "native-build.json").write_text(json.dumps({
            "version": 1, "component": "go", "target": target,
            "source": plan["sources"]["go"], "bootstrap_version": reported.split()[2],
            "cgo_enabled": False,
        }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        sdk.rename(output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("plan", "source-archive", "bootstrap-root", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text(encoding="utf-8"))
    try:
        build(plan, args.target, args.source_archive, args.bootstrap_root, args.output)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(f"native SDK build failed: {error}") from error
    print(f"Built upstream Go SDK at {args.output}")


if __name__ == "__main__":
    main()

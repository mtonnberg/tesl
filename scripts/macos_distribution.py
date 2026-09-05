"""Ad-hoc sign audited Mach-O files without a certificate or network service."""

from pathlib import Path, PurePosixPath
import subprocess

from native_source import sha256_file


def sign_payload(root, audit, policy):
    if (policy.get("macOSSigning") != "optional"
            or policy.get("macOSDistribution") != "ad-hoc-portable-archive"):
        raise ValueError("macOS builder requires the explicit ad-hoc distribution policy")
    root = Path(root).resolve()
    paths = []
    for binary in audit["binaries"]:
        relative = binary["path"]
        path = root / relative
        if (binary.get("format") != "Mach-O" or not relative
                or PurePosixPath(relative).is_absolute() or ".." in PurePosixPath(relative).parts
                or "\\" in relative or path.is_symlink() or not path.is_file()
                or not path.resolve().is_relative_to(root)):
            raise ValueError("invalid audited macOS binary")
        paths.append(path)
    if not paths or len(set(paths)) != len(paths):
        raise ValueError("macOS signing requires a unique, nonempty binary inventory")
    # Sign after all relocation/load-command edits and before archive hashes.
    # An ad-hoc signature has no publisher identity and is not notarization.
    for path in sorted(paths):
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(path)],
                       cwd=root, check=True, timeout=60, capture_output=True)
    binaries = []
    for path in sorted(paths):
        subprocess.run(["codesign", "--verify", "--strict", str(path)],
                       cwd=root, check=True, timeout=60, capture_output=True)
        binaries.append({"path": path.relative_to(root).as_posix(), "sha256": sha256_file(path).hex()})
    return {"mode": "ad-hoc", "verification": "passed", "publisher_identity": False,
            "notarized": False, "binaries": binaries}

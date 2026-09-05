"""Record the actual acceptance host separately from binary deployment targets."""

import os
import platform
import re
import sys


def inspect_host():
    result = {"system": platform.system(), "machine": platform.machine(),
              "kernel": platform.release(), "os_version": platform.version()}
    if sys.platform == "linux":
        try:
            result["libc"] = os.confstr("CS_GNU_LIBC_VERSION")
        except (OSError, ValueError):
            result["libc"] = None
    elif sys.platform == "darwin":
        result["macos_version"] = platform.mac_ver()[0]
    elif sys.platform == "win32":
        windows = sys.getwindowsversion()
        result["windows_version"] = list(windows.platform_version)
        # Matching kernel versions do not establish desktop Windows parity.
        result["windows_product_type"] = windows.product_type
    return result


def runtime_evidence(plan, target, host=None):
    host = inspect_host() if host is None else host
    baseline = next(row["baseline"] for row in plan["candidates"] if row["target"] == target)
    architecture = target.split("-")[1]
    machines = {"amd64": {"x86_64", "amd64"}, "arm64": {"aarch64", "arm64"}}
    correct_arch = host.get("machine", "").lower() in machines.get(architecture, set())
    matched = False
    if target.startswith("linux-"):
        # A successful workflow on newer glibc does not prove the lower bound.
        matched = host.get("system") == "Linux" and host.get("libc") == baseline
    elif target.startswith("darwin-"):
        requested = re.fullmatch(r"macOS ([0-9]+)(?:\.([0-9]+))?", baseline)
        actual = re.fullmatch(r"([0-9]+)\.([0-9]+)(?:\.[0-9]+)?", host.get("macos_version", ""))
        matched = (host.get("system") == "Darwin" and requested is not None and actual is not None
                   and requested[1] == actual[1] and (requested[2] is None or requested[2] == actual[2]))
    elif target == "windows-amd64":
        version = host.get("windows_version", [])
        matched = (baseline == "Windows 11" and host.get("system") == "Windows"
                   and host.get("windows_product_type") == 1 and len(version) == 3
                   and version[:2] == [10, 0] and isinstance(version[2], int) and version[2] >= 22000)
    return {"minimum_os_runtime": "passed" if correct_arch and matched else "not-established",
            "acceptance_host": {**host, "declared_baseline": baseline,
                                "matches_baseline": bool(correct_arch and matched)}}

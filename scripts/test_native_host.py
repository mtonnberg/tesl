"""Never infer minimum-OS execution from linker flags or a newer CI runner."""

import unittest
from unittest.mock import patch

import native_host


class HostTests(unittest.TestCase):
    def evidence(self, target, baseline, **host):
        plan = {"candidates": [{"target": target, "baseline": baseline}]}
        return native_host.runtime_evidence(plan, target, host)

    def test_linux_requires_exact_glibc_and_native_architecture(self):
        for target, machine in (("linux-amd64", "x86_64"), ("linux-arm64", "aarch64")):
            for libc, expected in (("glibc 2.35", "passed"), ("glibc 2.39", "not-established"),
                                   ("glibc 2.34", "not-established"), (None, "not-established")):
                with self.subTest(target=target, libc=libc):
                    result = self.evidence(target, "glibc 2.35", system="Linux", machine=machine, libc=libc)
                    self.assertEqual(result["minimum_os_runtime"], expected)
                    self.assertEqual(result["acceptance_host"]["libc"], libc)
            wrong = self.evidence(target, "glibc 2.35", system="Linux", machine="unrecognized", libc="glibc 2.35")
            self.assertEqual(wrong["minimum_os_runtime"], "not-established")

    def test_macos_newer_runner_does_not_establish_older_baseline(self):
        for version, expected in (("13.0", "passed"), ("13.7.1", "passed"), ("15.5", "not-established"),
                                  ("12.7", "not-established"), ("", "not-established")):
            with self.subTest(version=version):
                result = self.evidence("darwin-arm64", "macOS 13", system="Darwin", machine="arm64", macos_version=version)
                self.assertEqual(result["minimum_os_runtime"], expected)

    def test_macos_explicit_minor_baseline_is_respected(self):
        for version in ("13.0", "13.7"):
            result = self.evidence("darwin-amd64", "macOS 13.1", system="Darwin", machine="x86_64", macos_version=version)
            self.assertEqual(result["minimum_os_runtime"], "not-established")

    def test_windows_server_is_not_desktop_windows_even_on_the_same_kernel(self):
        for product, expected in ((1, "passed"), (2, "not-established"), (3, "not-established")):
            with self.subTest(product=product):
                result = self.evidence("windows-amd64", "Windows 11", system="Windows", machine="AMD64",
                                       windows_version=[10, 0, 26100], windows_product_type=product)
                self.assertEqual(result["minimum_os_runtime"], expected)
        old = self.evidence("windows-amd64", "Windows 11", system="Windows", machine="AMD64",
                            windows_version=[10, 0, 19045], windows_product_type=1)
        self.assertEqual(old["minimum_os_runtime"], "not-established")

    def test_system_identity_and_architecture_cannot_be_inferred_from_version(self):
        for system, machine in (("Windows", "x86_64"), ("Darwin", "arm64")):
            result = self.evidence("darwin-amd64", "macOS 13", system=system, machine=machine, macos_version="13.0")
            self.assertEqual(result["minimum_os_runtime"], "not-established")

    def test_unavailable_libc_is_recorded_without_claiming_success(self):
        with patch.object(native_host.sys, "platform", "linux"), \
                patch.object(native_host.os, "confstr", create=True, side_effect=ValueError("unavailable")):
            self.assertIsNone(native_host.inspect_host()["libc"])


if __name__ == "__main__":
    unittest.main()

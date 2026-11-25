"""Windows offline acceptance must fail closed and always restore the firewall."""

import errno
import json
import unittest
from unittest.mock import patch

import windows_network as network


class WindowsNetworkTests(unittest.TestCase):
    def test_only_firewall_policy_errors_count_as_denial(self):
        for code, accepted in ((10013, True), (errno.EACCES, True), (errno.EPERM, True),
                               (10060, False), (10061, False), (10051, False), (errno.ETIMEDOUT, False)):
            with self.subTest(code=code):
                def operation():
                    raise OSError(code, "probe")
                if accepted:
                    network.require_policy_denial(operation, "probe")
                else:
                    with self.assertRaisesRegex(ValueError, "without a firewall-policy denial"):
                        network.require_policy_denial(operation, "probe")
        with self.assertRaisesRegex(ValueError, "remains reachable"):
            network.require_policy_denial(lambda: None, "probe")

    def test_negative_control_must_be_off_host(self):
        for address in ("127.0.0.1", "10.1.0.4"):
            with self.subTest(address=address), self.assertRaisesRegex(ValueError, "off-host"):
                network.probe({"remote_address": address})

    def test_loopback_failure_is_not_reported_as_offline_success(self):
        with patch.object(network, "exchange", side_effect=OSError(10013, "loopback blocked")):
            with self.assertRaises(OSError):
                network.probe({"remote_address": "140.82.112.4", "token": "t", "tcp": 1, "udp": 2})

    def test_ipv6_is_required_only_when_the_host_had_an_ipv6_route(self):
        def connect(family, kind, address, port):
            raise OSError(10013, "blocked")
        with patch.object(network, "exchange"), patch.object(network, "remote_connection", side_effect=connect):
            without = network.probe({"remote_address": "140.82.112.4", "token": "t", "tcp": 1, "udp": 2})
            with_route = network.probe({"remote_address": "140.82.112.4", "remote_address6": "2606:50c0::1",
                                        "token": "t", "tcp": 1, "udp": 2})
        self.assertEqual(without, {"loopback": "passed", "tcp_ipv4": "denied", "udp_ipv4": "denied", "tcp_ipv6": "no-ipv6-route"})
        self.assertEqual(with_route["tcp_ipv6"], "denied")

    def test_reachable_ipv6_fails_even_when_ipv4_is_blocked(self):
        def connect(family, kind, address, port):
            if family == network.socket.AF_INET:
                raise OSError(10013, "blocked")
        with patch.object(network, "exchange"), patch.object(network, "remote_connection", side_effect=connect):
            with self.assertRaisesRegex(ValueError, "IPv6 tcp remains reachable"):
                network.probe({"remote_address": "140.82.112.4", "remote_address6": "2606:50c0::1",
                               "token": "t", "tcp": 1, "udp": 2})

    def test_rules_allow_only_runner_programs_and_dns(self):
        script = network.allow_rules_script([r"C:\actions-runner\bin\Runner.Worker.exe", r"C:\it's\node.exe"])
        self.assertEqual(script.count("-Action Allow"), 4)
        self.assertIn("-Program 'C:\\it''s\\node.exe'", script)
        self.assertEqual(script.count("-RemotePort 53"), 2)
        self.assertNotIn("Block", script)

    def test_missing_runner_refuses_to_block_the_machine(self):
        with patch.object(network, "powershell", return_value="null"):
            with self.assertRaisesRegex(ValueError, "cannot locate the GitHub Actions runner"):
                network.runner_programs()

    def test_previous_profiles_are_restored_even_when_acceptance_fails(self):
        saved = [{"Name": "Domain", "Enabled": "False", "Outbound": "NotConfigured"},
                 {"Name": "Public", "Enabled": "True", "Outbound": "Allow"}]
        scripts = []

        def powershell(script, capture=False):
            scripts.append(script)
            return json.dumps(saved) if capture else None
        with patch.object(network, "powershell", side_effect=powershell), \
                patch.object(network, "runner_programs", return_value=[r"C:\runner\bin\Runner.Worker.exe"]):
            with self.assertRaisesRegex(RuntimeError, "acceptance failed"):
                with network.outbound_blocked():
                    raise RuntimeError("acceptance failed")
        self.assertIn("-DefaultOutboundAction Block", scripts[-2])
        self.assertIn("Set-NetFirewallProfile -Name 'Domain' -Enabled False -DefaultOutboundAction NotConfigured", scripts[-1])
        self.assertIn("Set-NetFirewallProfile -Name 'Public' -Enabled True -DefaultOutboundAction Allow", scripts[-1])
        self.assertIn("Remove-NetFirewallRule", scripts[-1])

    def test_non_windows_hosts_refuse(self):
        with patch.object(network.sys, "platform", "linux"):
            with self.assertRaisesRegex(ValueError, "native Windows host"):
                network.run(["go"], ".", {})


if __name__ == "__main__":
    unittest.main()

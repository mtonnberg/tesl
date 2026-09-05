"""Fail closed when outbound denial or the installed workflow is unproven."""

from contextlib import contextmanager
import errno
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import macos_network as network


class NetworkTests(unittest.TestCase):
    def test_only_actual_policy_denials_pass(self):
        for code in (errno.EPERM, errno.EACCES, errno.ECONNREFUSED, errno.ETIMEDOUT, errno.ENETUNREACH):
            with self.subTest(code=code):
                def operation():
                    raise OSError(code, "probe")
                if code in (errno.EPERM, errno.EACCES):
                    network.require_policy_denial(operation)
                else:
                    with self.assertRaisesRegex(ValueError, "without a network-policy denial"):
                        network.require_policy_denial(operation)
        with self.assertRaisesRegex(ValueError, "remains reachable"):
            network.require_policy_denial(lambda: None)

    def test_negative_control_cannot_be_loopback(self):
        with self.assertRaisesRegex(ValueError, "non-loopback"):
            network.probe({"address": "127.0.0.1"})

    def test_loopback_failures_cannot_be_misreported_as_offline_success(self):
        with patch.object(network, "exchange", side_effect=OSError(errno.EPERM, "loopback denied")):
            with self.assertRaises(OSError):
                network.probe({"address": "192.0.2.1", "token": "test", "tcp": 12, "udp": 13})

    def test_probe_checks_tcp_udp_ipv4_and_ipv6(self):
        calls = []
        def exchange(address, port, kind, token):
            calls.append((address, port, kind, token))
            if address != "127.0.0.1":
                raise OSError(errno.EACCES, "denied")
        with patch.object(network, "exchange", side_effect=exchange), patch.object(network.socket, "socket") as opened:
            opened.return_value.__enter__.return_value.connect.side_effect = OSError(errno.EPERM, "denied")
            network.probe({"address": "192.0.2.1", "token": "test", "tcp": 12, "udp": 13})
        self.assertEqual([(address, kind) for address, _, kind, _ in calls],
                         [(address, kind) for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM)
                          for address in ("127.0.0.1", "192.0.2.1")])
        self.assertEqual([call.args for call in opened.call_args_list],
                         [(socket.AF_INET6, socket.SOCK_STREAM), (socket.AF_INET6, socket.SOCK_DGRAM)])

    def test_runner_preserves_arguments_and_cleans_controls_on_workflow_failure(self):
        closed = []
        @contextmanager
        def controls():
            try:
                yield {"address": "192.0.2.1", "token": "test", "tcp": 12, "udp": 13}
            finally:
                closed.append(True)
        for failed in (False, True):
            with self.subTest(failed=failed), patch.object(network.sys, "platform", "darwin"), \
                    patch.object(network, "controls", controls), patch.object(network.subprocess, "run") as run:
                if failed:
                    run.side_effect = subprocess.CalledProcessError(1, ["acceptance"])
                    with self.assertRaises(subprocess.CalledProcessError):
                        network.run(["/tools å/go", "test", "literal ; argument"], Path("/work"), {"X": "Y"}, 123)
                else:
                    result = network.run(["/tools å/go", "test", "literal ; argument"], Path("/work"), {"X": "Y"}, 123)
                    self.assertEqual(result["loopback_only_reachability"], "passed")
                args = run.call_args.args[0]
                self.assertEqual(args[:3], ["/usr/bin/sandbox-exec", "-p", network.PROFILE])
                self.assertEqual(args[-4:], ["--", "/tools å/go", "test", "literal ; argument"])
                self.assertEqual(run.call_args.kwargs["timeout"], 123)
                self.assertTrue(run.call_args.kwargs["check"])
        self.assertEqual(closed, [True, True])

    def test_failed_probe_never_executes_workflow(self):
        with patch.object(network.sys, "argv", ["probe", "--probe", "{}", "--", "go", "test"]), \
                patch.object(network, "probe", side_effect=ValueError("outbound reachable")), \
                patch.object(network.os, "execvpe") as execute:
            with self.assertRaisesRegex(ValueError, "outbound reachable"):
                network.main()
        execute.assert_not_called()

    @unittest.skipUnless(sys.platform == "darwin", "native macOS Seatbelt acceptance")
    def test_native_sandbox_probes_and_inherited_child_workflow(self):
        with tempfile.TemporaryDirectory(prefix="tesl network å ") as temporary:
            marker = Path(temporary) / "workflow passed"
            child = ("import macos_network as m, socket; "
                     "m.require_policy_denial(lambda: socket.create_connection(('192.0.2.1', 9), timeout=2))")
            script = ("import pathlib,subprocess,sys; "
                      f"subprocess.run([sys.executable, '-c', {child!r}], cwd={str(Path(__file__).resolve().parent)!r}, check=True); "
                      "pathlib.Path(sys.argv[1]).write_text('passed')")
            result = network.run([sys.executable, "-c", script, str(marker)], temporary, dict(os.environ), 30)
            self.assertEqual(marker.read_text(), "passed")
            self.assertEqual(result["network_isolation"], "macos-sandbox-exec")


if __name__ == "__main__":
    unittest.main()

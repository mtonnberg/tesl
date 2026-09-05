#!/usr/bin/env python3
"""Run native acceptance with inherited, probed macOS network restrictions.

The runner keeps its network access. Only the acceptance process and its children
enter Seatbelt; no machine-wide firewall settings or signing accounts are needed.
This is a CI-only use of sandbox-exec, never an installed runtime dependency.
"""

import argparse
from contextlib import contextmanager
import errno
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import threading


# An outbound rule must filter the REMOTE endpoint. A local-address exception
# also matches unbound sockets and would allow external connections.
PROFILE = '''(version 1)
(allow default)
(deny network*)
(allow network-bind)
(allow network-inbound)
(allow network-outbound (remote ip "localhost:*"))
(allow network-outbound (remote unix-socket (path-regex #"^/")))
'''


def exchange(address, port, kind, token):
    with socket.socket(socket.AF_INET, kind) as connection:
        connection.settimeout(3)
        connection.connect((address, port))
        if kind == socket.SOCK_STREAM:
            connection.sendall(token)
        else:
            connection.send(token)
        if connection.recv(1024) != token:
            raise ValueError("network probe did not reach its own listener")


def require_policy_denial(operation):
    try:
        operation()
    except OSError as error:
        if error.errno in (errno.EPERM, errno.EACCES):
            return
        raise ValueError("outbound probe failed without a network-policy denial") from error
    raise ValueError("outbound network remains reachable")


def probe(configuration):
    address = configuration["address"]
    if ipaddress.ip_address(address).is_loopback:
        raise ValueError("negative control must use a non-loopback address")
    token = configuration["token"].encode("ascii")
    for name, kind in (("tcp", socket.SOCK_STREAM), ("udp", socket.SOCK_DGRAM)):
        port = configuration[name]
        exchange("127.0.0.1", port, kind, token)
        require_policy_denial(lambda: exchange(address, port, kind, token))
        # Even hosts without an IPv6 route must reject the operation by policy,
        # not merely time out or return "network unreachable". No DNS is used.
        def ipv6():
            with socket.socket(socket.AF_INET6, kind) as connection:
                connection.settimeout(3)
                connection.connect(("2001:db8::1", port))
                connection.send(token)
        require_policy_denial(ipv6)


@contextmanager
def controls():
    # UDP connect selects the interface without sending any network traffic.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as route:
        route.connect(("192.0.2.1", 9))
        address = route.getsockname()[0]
    if ipaddress.ip_address(address).is_loopback or ipaddress.ip_address(address).is_unspecified:
        raise ValueError("offline acceptance requires a non-loopback positive control")
    configuration = {"address": address, "token": secrets.token_hex(24)}
    stopped = threading.Event()
    listeners, workers = [], []

    def serve(listener, kind):
        while not stopped.is_set():
            try:
                if kind == socket.SOCK_STREAM:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(1)
                        data = connection.recv(1024)
                        connection.sendall(data)
                else:
                    data, sender = listener.recvfrom(1024)
                    listener.sendto(data, sender)
            except socket.timeout:
                continue

    try:
        for name, kind in (("tcp", socket.SOCK_STREAM), ("udp", socket.SOCK_DGRAM)):
            listener = socket.socket(socket.AF_INET, kind)
            listeners.append(listener)
            listener.bind(("0.0.0.0", 0))
            listener.settimeout(0.2)
            if kind == socket.SOCK_STREAM:
                listener.listen()
            configuration[name] = listener.getsockname()[1]
            worker = threading.Thread(target=serve, args=(listener, kind), daemon=True)
            worker.start()
            workers.append(worker)
            exchange(address, configuration[name], kind, configuration["token"].encode("ascii"))
        yield configuration
    finally:
        stopped.set()
        for worker in workers:
            worker.join(timeout=2)
        for listener in listeners:
            listener.close()


def run(arguments, root, environment, timeout=1500):
    if sys.platform != "darwin":
        raise ValueError("macOS network acceptance requires a native macOS host")
    with controls() as configuration:
        # The probe runs in a child of sandbox-exec, then execs the entire test
        # command. Its Go/compiler/server children inherit the same restrictions.
        command = ["/usr/bin/sandbox-exec", "-p", PROFILE, sys.executable,
                   str(Path(__file__).resolve()), "--probe", json.dumps(configuration),
                   "--", *map(str, arguments)]
        subprocess.run(command, cwd=root, env=environment, check=True, timeout=timeout)
    return {"network_isolation": "macos-sandbox-exec", "loopback_only_reachability": "passed"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("missing acceptance command")
    probe(json.loads(args.probe))
    print("Verified macOS loopback TCP/UDP and denied outbound IPv4/IPv6", flush=True)
    os.execvpe(command[0], command, os.environ)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Run native Windows acceptance with outbound network traffic blocked.

Windows has no per-process sandbox comparable to Linux network namespaces or
macOS sandbox-exec, so this uses Windows Firewall for the whole CI machine:

1. Record each firewall profile's current state.
2. Allow outbound traffic only for the GitHub Actions runner's own programs
   (so the job keeps reporting) and for DNS through the DNS client service.
3. Turn every profile on with "block outbound" as the default.
4. In a separate, non-allowed process, prove that loopback still works and
   that an off-host TCP connection is refused by policy (WSAEACCES), not by a
   timeout or an unreachable route.
5. Run the installed-workflow acceptance, then restore the recorded state.

Loopback traffic (the managed PostgreSQL server) is not filtered by Windows
Firewall. This is CI-only: it changes machine-wide settings and must never run
on a developer machine; installed Tesl does not depend on it.
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


GROUP = "Tesl offline acceptance"
POLICY_DENIED = {errno.EACCES, errno.EPERM, 10013}  # 10013 = WSAEACCES
RUNNER_PROCESSES = ("Runner.Worker", "Runner.Listener")


def powershell(script, capture=False):
    result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                            check=True, capture_output=capture, text=True, timeout=300)
    return result.stdout if capture else None


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def denied_by_policy(error):
    return error.errno in POLICY_DENIED or getattr(error, "winerror", None) in POLICY_DENIED


def require_policy_denial(operation, context):
    try:
        operation()
    except OSError as error:
        if denied_by_policy(error):
            return
        raise ValueError(f"{context} probe failed without a firewall-policy denial") from error
    raise ValueError(f"{context} remains reachable")


def remote_connection(family, kind, address, port):
    with socket.socket(family, kind) as connection:
        connection.settimeout(5)
        connection.connect((address, port))
        if kind == socket.SOCK_DGRAM:
            connection.send(b"")


def exchange(port, kind, token):
    with socket.socket(socket.AF_INET, kind) as connection:
        connection.settimeout(3)
        connection.connect(("127.0.0.1", port))
        if kind == socket.SOCK_STREAM:
            connection.sendall(token)
        else:
            connection.send(token)
        if connection.recv(1024) != token:
            raise ValueError("loopback probe did not reach its own listener")


def probe(configuration):
    """Runs in a child process that has no firewall allow rule."""
    address = configuration["remote_address"]
    if not ipaddress.ip_address(address).is_global:
        raise ValueError("negative control must use an off-host public address")
    token = configuration["token"].encode("ascii")
    for name, kind in (("tcp", socket.SOCK_STREAM), ("udp", socket.SOCK_DGRAM)):
        exchange(configuration[name], kind, token)
    # TCP is the decisive check: a blocked connect fails at once with WSAEACCES.
    require_policy_denial(lambda: remote_connection(socket.AF_INET, socket.SOCK_STREAM, address, 443),
                          "off-host IPv4 tcp")
    result = {"loopback": "passed", "tcp_ipv4": "denied"}
    # Windows may drop a blocked UDP datagram silently instead of failing the
    # send, so UDP is recorded rather than required.
    try:
        remote_connection(socket.AF_INET, socket.SOCK_DGRAM, address, 443)
        result["udp_ipv4"] = "not-observable"
    except OSError as error:
        result["udp_ipv4"] = "denied" if denied_by_policy(error) else "failed-other"
    remote6 = configuration.get("remote_address6")
    if remote6:
        require_policy_denial(lambda: remote_connection(socket.AF_INET6, socket.SOCK_STREAM, remote6, 443),
                              "off-host IPv6 tcp")
        result["tcp_ipv6"] = "denied"
    else:
        result["tcp_ipv6"] = "no-ipv6-route"
    return result


def positive_control(family):
    """An off-host address reachable BEFORE blocking, or None for no route."""
    try:
        rows = socket.getaddrinfo("github.com", 443, family, socket.SOCK_STREAM)
    except OSError:
        return None
    for remote in sorted({row[4][0] for row in rows})[:3]:
        if not ipaddress.ip_address(remote).is_global:
            continue
        try:
            remote_connection(family, socket.SOCK_STREAM, remote, 443)
            return remote
        except OSError:
            continue
    return None


@contextmanager
def loopback_listeners(configuration):
    stopped = threading.Event()
    listeners, workers = [], []

    def serve(listener, kind):
        while not stopped.is_set():
            try:
                if kind == socket.SOCK_STREAM:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(1)
                        connection.sendall(connection.recv(1024))
                else:
                    data, sender = listener.recvfrom(1024)
                    listener.sendto(data, sender)
            except (socket.timeout, ConnectionResetError):
                continue

    try:
        for name, kind in (("tcp", socket.SOCK_STREAM), ("udp", socket.SOCK_DGRAM)):
            listener = socket.socket(socket.AF_INET, kind)
            listeners.append(listener)
            listener.bind(("127.0.0.1", 0))
            listener.settimeout(0.2)
            if kind == socket.SOCK_STREAM:
                listener.listen()
            configuration[name] = listener.getsockname()[1]
            worker = threading.Thread(target=serve, args=(listener, kind), daemon=True)
            worker.start()
            workers.append(worker)
        yield configuration
    finally:
        stopped.set()
        for worker in workers:
            worker.join(timeout=2)
        for listener in listeners:
            listener.close()


def runner_programs():
    """Every executable shipped with the Actions runner, found from its live processes."""
    output = powershell("(Get-Process " + ",".join(RUNNER_PROCESSES)
                        + " -ErrorAction SilentlyContinue).Path | ConvertTo-Json", capture=True)
    paths = json.loads(output or "null")
    paths = [paths] if isinstance(paths, str) else (paths or [])
    roots = {Path(path).resolve().parent.parent for path in paths if path}
    if not roots:
        raise ValueError("cannot locate the GitHub Actions runner; refusing to block outbound traffic")
    programs = sorted({str(path) for root in roots for path in root.rglob("*.exe")})
    if not programs:
        raise ValueError("GitHub Actions runner has no executables to allow")
    return programs


def allow_rules_script(programs):
    lines = [f"New-NetFirewallRule -Group {quote(GROUP)} -DisplayName {quote(GROUP + ' runner')} "
             f"-Direction Outbound -Action Allow -Program {quote(program)} | Out-Null" for program in programs]
    svchost = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "svchost.exe")
    for protocol in ("UDP", "TCP"):
        lines.append(f"New-NetFirewallRule -Group {quote(GROUP)} -DisplayName {quote(GROUP + ' DNS')} "
                     f"-Direction Outbound -Action Allow -Protocol {protocol} -RemotePort 53 "
                     f"-Program {quote(svchost)} | Out-Null")
    return "\n".join(lines)


def restore_script(saved):
    lines = [f"Set-NetFirewallProfile -Name {quote(row['Name'])} -Enabled {row['Enabled']} "
             f"-DefaultOutboundAction {row['Outbound']}" for row in saved]
    lines.append(f"Remove-NetFirewallRule -Group {quote(GROUP)} -ErrorAction SilentlyContinue")
    return "\n".join(lines)


@contextmanager
def outbound_blocked():
    saved = json.loads(powershell(
        "Get-NetFirewallProfile | Select-Object Name,"
        "@{n='Enabled';e={$_.Enabled.ToString()}},"
        "@{n='Outbound';e={$_.DefaultOutboundAction.ToString()}} | ConvertTo-Json", capture=True))
    saved = [saved] if isinstance(saved, dict) else saved
    if not saved or any(set(row) != {"Name", "Enabled", "Outbound"} for row in saved):
        raise ValueError("cannot record the current firewall profiles")
    programs = runner_programs()
    try:
        powershell(allow_rules_script(programs))
        powershell("Set-NetFirewallProfile -All -Enabled True -DefaultOutboundAction Block")
        yield
    finally:
        powershell(restore_script(saved))


def run(arguments, root, environment, timeout=1500):
    if sys.platform != "win32":
        raise ValueError("Windows network acceptance requires a native Windows host")
    configuration = {"token": secrets.token_hex(24), "remote_address": positive_control(socket.AF_INET)}
    if configuration["remote_address"] is None:
        raise ValueError("cannot establish an off-host positive control")
    configuration["remote_address6"] = positive_control(socket.AF_INET6)
    with loopback_listeners(configuration), outbound_blocked():
        probed = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--probe", json.dumps(configuration)],
                                cwd=root, env=environment, check=True, capture_output=True, text=True, timeout=120)
        result = json.loads(probed.stdout.strip().splitlines()[-1])
        print("Verified Windows loopback and firewall-denied off-host traffic: " + json.dumps(result), flush=True)
        subprocess.run([str(argument) for argument in arguments], cwd=root, env=environment, check=True, timeout=timeout)
    return {"network_isolation": "windows-firewall", "windows_firewall_probe": result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", required=True)
    args = parser.parse_args()
    print(json.dumps(probe(json.loads(args.probe)), sort_keys=True), flush=True)


if __name__ == "__main__":
    main()

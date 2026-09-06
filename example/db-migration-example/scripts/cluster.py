#!/usr/bin/env python3
"""Local two-node rolling example; requests use a real HTTP reverse proxy.

No write is retried. A retiring node is removed from routing, drained, then stopped.
This intentionally small local runner is not an internet-facing production proxy.
"""
import http.client
import http.server
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid


class Pool:
    def __init__(self):
        self.condition = threading.Condition()
        self.nodes = []
        self.active = {}
        self.next = 0

    def choose(self):
        with self.condition:
            if not self.nodes:
                raise RuntimeError("no ready backends")
            node = self.nodes[self.next % len(self.nodes)]
            self.next += 1
            self.active[node] = self.active.get(node, 0) + 1
            return node

    def release(self, node):
        with self.condition:
            self.active[node] -= 1
            self.condition.notify_all()

    def add(self, node):
        with self.condition:
            self.nodes.append(node)

    def drain(self, node):
        with self.condition:
            self.nodes.remove(node)
            self.condition.notify_all()
            if not self.condition.wait_for(lambda: self.active.get(node, 0) == 0, timeout=20):
                raise RuntimeError("retiring request node did not drain")


pool = Pool()
frontend = None


class Proxy(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(frontend), **kwargs)

    def do_GET(self):
        if self.path.startswith("/api/"):
            self.forward()
        else:
            super().do_GET()

    def do_POST(self):
        self.forward()

    def do_PUT(self):
        self.forward()

    def do_DELETE(self):
        self.forward()

    def forward(self):
        node = None
        connection = None
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 0 or length > 1_048_576:
                self.send_error(413)
                return
            body = self.rfile.read(length) if length else None
            node = pool.choose()
            connection = http.client.HTTPConnection("127.0.0.1", node, timeout=10)
            headers = {"Content-Type": self.headers.get("Content-Type", "application/json")}
            connection.request(self.command, self.path, body, headers)
            response = connection.getresponse()
            payload = response.read()
            self.send_response(response.status)
            self.send_header("Content-Type", response.getheader("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("X-Todo-Backend", str(node))
            self.end_headers()
            self.wfile.write(payload)
        except (OSError, ValueError, RuntimeError, http.client.HTTPException) as error:
            self.log_error("proxy failure: %s", type(error).__name__)
            self.send_error(502, "backend request failed; request was not retried")
        finally:
            if connection is not None:
                connection.close()
            if node is not None:
                pool.release(node)

    def log_message(self, *args):
        pass


def request(port, method, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as response:
        if response.status != 200:
            raise RuntimeError(f"{method} {path}: status {response.status}")
        return json.load(response)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def main():
    global frontend
    if len(sys.argv) != 4:
        sys.exit("usage: cluster.py RELEASE_DIRECTORY FRONTEND_DIRECTORY PROXY_PORT")
    releases = Path(sys.argv[1]).resolve()
    frontend = Path(sys.argv[2]).resolve()
    proxy_port = int(sys.argv[3])
    processes = []
    logs = []
    probe_stop = threading.Event()
    probe_failures = []
    count = [0]
    base = dict(os.environ)
    worker = None
    server = None
    thread = None

    def launch(version, role, port=None):
        env = dict(base, TODO_DB_USER=role, PGUSER=role)
        command = [str(releases / f"v{version}" / "app")]
        if port is None:
            command += ["--schema", "worker", "--json"]
        else:
            env["TODO_HTTP_PORT"] = str(port)
        log = (releases / f"v{version}-{role}-{port or 'worker'}.log").open("ab")
        logs.append(log)
        process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
        processes.append(process)
        return process

    def ready(process, port):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f"node exited before readiness; see {releases}")
            try:
                if request(port, "GET", "/api/health") == {"status": "ready"}:
                    return
            except (OSError, ValueError):
                time.sleep(0.1)
        raise RuntimeError("new node readiness timed out; old node remains in routing")

    def probe():
        while not probe_stop.is_set():
            try:
                key = "probe-" + str(uuid.uuid4())
                url = "/api/todos/" + key
                created = request(proxy_port, "POST", url, {"title": "Rolling deployment probe"})
                assert created == {"id": key, "title": "Rolling deployment probe", "completed": False}
                updated = request(proxy_port, "PUT", url, {"title": "Probe completed", "completed": True})
                assert request(proxy_port, "GET", url) == updated
                assert updated == {"id": key, "title": "Probe completed", "completed": True}
                assert request(proxy_port, "DELETE", url) == {"id": key, "deleted": True}
                count[0] += 1
            except Exception as error:
                probe_failures.append(error)
                return
            probe_stop.wait(0.1)

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    try:
        worker = launch(1, base["TODO_WORKER_ROLE"])
        nodes = []
        for port in (proxy_port + 1, proxy_port + 2):
            process = launch(1, base["TODO_REQUEST_ROLE"], port)
            ready(process, port)
            pool.add(port)
            nodes.append((process, port))
        server = http.server.ThreadingHTTPServer(("127.0.0.1", proxy_port), Proxy)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        thread = threading.Thread(target=probe, daemon=True)
        thread.start()
        print(f"Field Notes: http://127.0.0.1:{proxy_port} — rolling V1 → V7 with continuous CRUD", flush=True)
        spare = proxy_port + 3
        for version in range(2, 8):
            time.sleep(2)
            if probe_failures:
                raise RuntimeError("continuous request probe failed") from probe_failures[0]
            stop(worker)
            worker = launch(version, base["TODO_WORKER_ROLE"])
            for position in range(2):
                old, old_port = nodes[position]
                new = launch(version, base["TODO_REQUEST_ROLE"], spare)
                ready(new, spare)  # Does not route or stop either healthy old instance early.
                pool.add(spare)
                pool.drain(old_port)
                stop(old)
                nodes[position] = (new, spare)
                spare = old_port
            print(f"V{version}: both nodes ready, {count[0]} continuous CRUD cycles passed", flush=True)
        print("Rollout complete. The Elm UI remains live; Ctrl-C stops the app, PostgreSQL data remains.", flush=True)
        while True:
            time.sleep(1)
            if probe_failures:
                raise RuntimeError("continuous request probe failed") from probe_failures[0]
            if worker.poll() is not None or any(p.poll() is not None for p, _ in nodes):
                raise RuntimeError("a cluster process exited; see release logs")
    except KeyboardInterrupt:
        pass
    except Exception as error:
        if server is None:
            raise
        print(f"Rollout paused: {error}. Existing routed nodes stay live. Logs: {releases}", flush=True)
        print("Inspect the failure; Ctrl-C explicitly stops the app.", flush=True)
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass
    finally:
        probe_stop.set()
        # Finish the in-flight CRUD cycle while its proxy and backends are still
        # alive. A normal Ctrl-C must not manufacture a migration failure.
        if thread is not None:
            thread.join(timeout=60)
            if thread.is_alive():
                probe_failures.append(RuntimeError("probe did not finish before shutdown"))
        if server is not None:
            server.shutdown()
            server.server_close()
        for process in reversed(processes):
            stop(process)
        for log in logs:
            log.close()
        print(f"Stopped; {count[0]} successful complete CRUD cycles, {len(probe_failures)} probe failures.")


if __name__ == "__main__":
    main()

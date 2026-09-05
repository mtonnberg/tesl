#!/usr/bin/env python3
"""Exercise the official starter through the real CLI (requires Go and sockets)."""
import os
import json
import re
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request

repo = Path(__file__).resolve().parent.parent
env = {**os.environ, "TESL_REPO_ROOT": str(repo)}
env.setdefault("TESL_OCAML_COMPILER", str(repo / "compiler/_build/default/bin/main.exe"))
cli = ["bash", str(repo / "nix/tesl-cli-body.sh")]
# Refuse to mistake an unrelated existing server for this test's process.
with socket.socket() as probe:
    probe.bind(("127.0.0.1", 8086))
with tempfile.TemporaryDirectory(prefix="tesl-playground-runtime-") as directory:
    work = Path(directory)
    for filename, module in [("hello-server.tesl", "HelloServer"), ("customer-invoice.tesl", "CustomerInvoice")]:
        (work / f"{module}.tesl").write_text((repo / "example/playground" / filename).read_text())
    subprocess.run(cli + ["test", "CustomerInvoice.tesl"], cwd=work, env=env, check=True, timeout=120)
    subprocess.run(cli + ["check", "HelloServer.tesl"], cwd=work, env=env, check=True, timeout=30)
    with (work / "server.log").open("w") as log:
        server = subprocess.Popen(cli + ["run", "HelloServer.tesl"], cwd=work, env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if server.poll() is not None:
                    raise RuntimeError("Server exited: " + (work / "server.log").read_text())
                try:
                    with urllib.request.urlopen("http://127.0.0.1:8086/hello", timeout=1) as response:
                        body = response.read().decode()
                        assert response.status == 200 and body == '"Hello from Tesl!"', body
                        print(f"PASS CLI check + run: GET /hello -> {response.status} {body}")
                        break
                except OSError:
                    time.sleep(.2)
            else:
                raise RuntimeError("Server did not start: " + (work / "server.log").read_text())
        finally:
            try:
                os.killpg(server.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid, signal.SIGKILL)
                server.wait()

# Exercise both the displayed test examples and their suggested additions.
# These run in the local Go test harness, including a small bounded load test.
with tempfile.TemporaryDirectory(prefix="tesl-playground-test-chapter-") as directory:
    for example in json.loads((repo / "playground/examples.json").read_text()):
        if not example.get("run_tests"):
            continue
        source = (repo / "example/playground" / example["file"]).read_text()
        for variant, text in [("starter", source), ("exercise", source.replace(*example["repair"]))]:
            work = Path(directory) / (example["file"] + "-" + variant)
            work.mkdir()
            module = re.search(r"^module (\w+)", text).group(1)
            target = work / (module + ".tesl")
            target.write_text(text)
            subprocess.run([env["TESL_OCAML_COMPILER"], "agent-context", str(target)], env=env, check=True, timeout=30)
            subprocess.run(cli + ["test", target.name], cwd=work, env=env, check=True, timeout=120)
            print(f"PASS testing chapter: {example['file']} ({variant})", flush=True)

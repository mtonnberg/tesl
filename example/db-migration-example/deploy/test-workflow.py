#!/usr/bin/env python3
"""Archive/compiler boundary and live HTTP proxy tests; no PostgreSQL required."""
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

APP = Path(__file__).resolve().parents[1]
ROOT = APP.parents[1]
COMPILER = Path(os.environ.get("TESL_COMPILER", ROOT / "compiler/_build/default/bin/main.exe"))
spec = importlib.util.spec_from_file_location("todo_cluster", APP / "deploy/cluster.py")
cluster = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cluster)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tesl-todo-workflow-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def prepare(self, n):
        output = self.directory / f"v{n}"
        subprocess.run(["bash", str(APP / "deploy/build-revision.sh"), str(n), str(output), "--prepare-only"],
                       check=True, capture_output=True, text=True)
        return output

    def check(self, source):
        self.assertTrue(COMPILER.is_file(), "build the compiler first or set TESL_COMPILER")
        env = dict(os.environ, TESL_REPO_ROOT=str(ROOT))
        result = subprocess.run([str(COMPILER), "agent-context", str(source / "todo-app.tesl")],
                                capture_output=True, text=True, env=env, timeout=60)
        return result, json.loads(result.stdout)

    def test_all_releases_keep_app_and_frozen_predecessors_exact(self):
        current_app = (APP / "todo-app.tesl").read_bytes()
        for revision in range(1, 10):
            with self.subTest(revision=revision):
                output = self.prepare(revision)
                source = output / "source"
                self.assertEqual(current_app, (source / "todo-app.tesl").read_bytes())
                report = json.loads((output / "release.json").read_text())
                self.assertEqual(hashlib.sha256(current_app).hexdigest(), report["appSha256"])
                for relative, expected in report["sourceSha256"].items():
                    self.assertEqual(hashlib.sha256((source / relative).read_bytes()).hexdigest(), expected)
                for earlier in range(1, revision):
                    path = APP / "schema/todo" / f"v{earlier}.tesl"
                    self.assertEqual(path.read_bytes(), (source / path.relative_to(APP)).read_bytes())
                    self.assertFalse((source / "schema/todo" / f"v{earlier}").exists())
                    if earlier > 1:
                        path = APP / "migrations/todo" / f"v{earlier}.tesl"
                        self.assertEqual(path.read_bytes(), (source / path.relative_to(APP)).read_bytes())
                result, diagnostics = self.check(source)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(diagnostics["diagnostics"], [])
                self.assertEqual(diagnostics["proof_obligations"], [])

    def test_frozen_source_mutation_is_refused_by_actual_compiler(self):
        output = self.prepare(9)
        frozen = output / "source/schema/todo/v1.tesl"
        frozen.write_text(frozen.read_text() + "\n# A later edit is not the recorded source.\n")
        result, diagnostics = self.check(output / "source")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MIG013", [d["code"] for d in diagnostics["diagnostics"]])

    def test_editable_target_change_requires_refresh(self):
        output = self.prepare(9)
        current = output / "source/schema/todo/v-current.tesl"
        current.write_text(current.read_text() + "\n# An editable change still requires a checked refresh.\n")
        result, diagnostics = self.check(output / "source")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MIG001", [d["code"] for d in diagnostics["diagnostics"]])

    def test_emission_prints_failed_compiler_diagnostics_and_keeps_the_report(self):
        copy = self.directory / "app-copy"
        shutil.copytree(APP, copy, ignore=shutil.ignore_patterns(".local*", "elm-stuff", "main.js", "__pycache__"))
        frozen = copy / "schema/todo/v1.tesl"
        frozen.write_text(frozen.read_text() + "\n# Changed frozen input must be reported.\n")
        output = self.directory / "refused-emission"
        env = dict(os.environ, TESL_COMPILER=str(COMPILER), TESL_REPO_ROOT=str(ROOT))
        result = subprocess.run(["bash", str(copy / "deploy/build-revision.sh"), "2", str(output), "--emit-only"],
                                env=env, capture_output=True, text=True, timeout=60)
        self.assertNotEqual(result.returncode, 0)
        report = (output / "diagnostics.json").read_text()
        self.assertIn("MIG013", [d["code"] for d in json.loads(report)["diagnostics"]])
        self.assertIn(report.strip(), result.stderr)
        self.assertIn(str(output / "diagnostics.json"), result.stderr)
        self.assertFalse((output / "go").exists())

    def test_invalid_revision_and_existing_output_do_not_mutate_output(self):
        output = self.directory / "existing"
        output.mkdir()
        sentinel = output / "keep.txt"
        sentinel.write_text("user data")
        for revision in ("0", "10", "../1", "1"):
            result = subprocess.run(["bash", str(APP / "deploy/build-revision.sh"), revision, str(output), "--prepare-only"],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(), "user data")
            self.assertEqual(list(output.iterdir()), [sentinel])

    def test_changed_application_refuses_archived_comparison(self):
        copy = self.directory / "app-copy"
        shutil.copytree(APP, copy, ignore=shutil.ignore_patterns(".local*", "elm-stuff", "main.js", "__pycache__"))
        path = copy / "todo-app.tesl"
        path.write_text(path.read_text() + "\n# Changed handler/application snapshot.\n")
        result = subprocess.run(["bash", str(copy / "deploy/build-revision.sh"), "9", str(self.directory / "refused"), "--prepare-only"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reviewed unchanged app", result.stderr)
        self.assertFalse((self.directory / "refused").exists())


class LocalScriptTests(unittest.TestCase):
    def test_new_family_uses_a_distinct_default_data_directory(self):
        env = dict(os.environ)
        env.pop("TODO_LOCAL_DIR", None)
        result = subprocess.run(["bash", "-c", 'source "$1"; printf "%s" "$TODO_LOCAL_DIR"',
                                 "bash", str(APP / "deploy/local-env.sh")], env=env,
                                capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout, str(APP / ".local-schema-todo-v5"))

    def test_ambient_postgres_configuration_cannot_redirect_local_children(self):
        env = dict(os.environ, TODO_LOCAL_DIR=str(APP / ".local"), TODO_DB_PORT="55439", PGHOST="other-db.invalid", PGPORT="6543",
                   PGDATABASE="other_database", PGUSER="administrator", PGPASSWORD="not-used",
                   PGSERVICE="other_service", PGSERVICEFILE="other_service_file",
                   PGHOSTADDR="192.0.2.1", PGOPTIONS="-c search_path=other")
        command = """source "$1"; python3 -c 'import json,os; print(json.dumps({k:v for k,v in os.environ.items() if k.startswith("PG")}))'"""
        result = subprocess.run(["bash", "-c", command,
                                 "bash", str(APP / "deploy/local-env.sh")],
                                env=env, capture_output=True, text=True, check=True)
        actual = json.loads(result.stdout)
        self.assertEqual(actual["PGHOST"], "127.0.0.1")
        self.assertEqual(actual["PGPORT"], "55439")
        self.assertEqual(actual["PGDATABASE"], "todo_demo")
        self.assertEqual(actual["PGUSER"], "todo_app")
        self.assertEqual(actual["PGPASSWORD"], "")
        self.assertEqual(actual["PGPASSFILE"], str(APP / ".local/postgres/pgpass.disabled"))
        self.assertEqual(actual["PGSSLMODE"], "disable")
        for key in ("PGSERVICE", "PGSERVICEFILE", "PGHOSTADDR", "PGOPTIONS"):
            self.assertNotIn(key, actual)

    def test_stop_refuses_unowned_postgres_directory_before_invoking_pg_ctl(self):
        with tempfile.TemporaryDirectory(prefix="tesl-todo-stop-test-") as directory:
            root = Path(directory)
            (root / "postgres").mkdir()
            (root / "postgres/PG_VERSION").write_text("17\n")
            (root / "pg_ctl").write_text("#!/bin/sh\necho invoked > \"$TODO_LOCAL_DIR/invoked\"\nexit 0\n")
            (root / "pg_ctl").chmod(0o700)
            env = dict(os.environ, TODO_LOCAL_DIR=directory, PATH=directory + os.pathsep + os.environ["PATH"])
            result = subprocess.run(["bash", str(APP / "deploy/stop-local.sh")], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not created by this demo", result.stderr)
            self.assertFalse((root / "invoked").exists())

    def test_setup_refuses_the_legacy_family_without_touching_retained_data(self):
        for marker in ("Field Notes local PostgreSQL cluster", "Field Notes Schema.Todo local PostgreSQL cluster"):
            with self.subTest(marker=marker):
                self.check_retained_directory_refused(marker)

    def check_retained_directory_refused(self, marker):
        with tempfile.TemporaryDirectory(prefix="tesl-todo-family-test-") as directory:
            root = Path(directory)
            (root / "postgres").mkdir()
            (root / "postgres/PG_VERSION").write_text("17\n")
            (root / "postgres/retained-row-evidence").write_bytes(b"old demo data\x00")
            (root / "todo-demo-cluster").write_text(marker + "\n")
            tools = root / "tools"
            tools.mkdir()
            for name in ("initdb", "pg_ctl", "psql"):
                command = tools / name
                command.write_text('#!/bin/sh\necho invoked > "$TODO_LOCAL_DIR/invoked"\nexit 0\n')
                command.chmod(0o700)
            before = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()}
            env = dict(os.environ, TODO_LOCAL_DIR=directory, PATH=str(tools) + os.pathsep + os.environ["PATH"])
            result = subprocess.run(["bash", str(APP / "deploy/setup-local.sh")], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("different identity", result.stderr)
            self.assertIn("fresh TODO_LOCAL_DIR", result.stderr)
            self.assertFalse((root / "invoked").exists())
            self.assertEqual(before, {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()})
            self.assertFalse((root / "socket").exists())


class ProxyTests(unittest.TestCase):
    def test_drain_removes_old_node_before_waiting_for_inflight_request(self):
        pool = cluster.Pool()
        pool.add(1)
        self.assertEqual(pool.choose(), 1)
        pool.add(2)
        finished = threading.Event()
        draining = threading.Event()

        def drain():
            draining.set()
            pool.drain(1)
            finished.set()

        thread = threading.Thread(target=drain)
        thread.start()
        self.assertTrue(draining.wait(1))
        with pool.condition:
            self.assertTrue(pool.condition.wait_for(lambda: 1 not in pool.nodes, timeout=1))
        self.assertFalse(finished.is_set())
        self.assertEqual(pool.choose(), 2)
        pool.release(2)
        pool.release(1)
        self.assertTrue(finished.wait(1))
        thread.join(timeout=1)

    def test_real_http_proxy_preserves_methods_bodies_and_errors_without_retry(self):
        seen = []

        class Backend(http.server.BaseHTTPRequestHandler):
            def handle_request(self):
                seen.append((self.command, self.path, self.rfile.read(int(self.headers.get("Content-Length", "0")))))
                status = 409 if self.path.endswith("duplicate") else 200
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"ok":true}')

            do_GET = do_POST = do_PUT = do_DELETE = handle_request

            def log_message(self, *_args):
                pass

        def serve(handler):
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            return server.server_address[1]

        backend = serve(Backend)
        cluster.pool = cluster.Pool()
        cluster.pool.add(backend)
        cluster.frontend = APP / "frontend"
        proxy = serve(cluster.Proxy)
        for method in ("GET", "POST", "PUT", "DELETE"):
            payload = None if method in ("GET", "DELETE") else {"title": "with spaces", "completed": False}
            self.assertEqual(cluster.request(proxy, method, "/api/todos/one", payload), {"ok": True})
        req = urllib.request.Request(f"http://127.0.0.1:{proxy}/api/todos/duplicate", data=b'{}', method="POST")
        with self.assertRaises(urllib.error.HTTPError) as failure:
            urllib.request.urlopen(req, timeout=5)
        self.assertEqual(failure.exception.code, 409)
        self.assertEqual([method for method, _, _ in seen], ["GET", "POST", "PUT", "DELETE", "POST"])
        self.assertEqual(json.loads(seen[1][2]), {"title": "with spaces", "completed": False})
        with urllib.request.urlopen(f"http://127.0.0.1:{proxy}/", timeout=5) as page:
            self.assertEqual(page.status, 200)
            self.assertIn(b"Field Notes", page.read())
        self.assertEqual(len(seen), 5, "static page or failed write was unexpectedly forwarded/retried")


if __name__ == "__main__":
    unittest.main(verbosity=2)

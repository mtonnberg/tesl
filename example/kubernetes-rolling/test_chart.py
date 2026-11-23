"""Credential scopes and ordering of the rendered chart; requires helm only.

run.py executes this before creating a cluster. Run it alone with
`python3 example/kubernetes-rolling/test_chart.py` inside `nix develop .#kubernetes`.
"""
from pathlib import Path
import re
import shutil
import subprocess
import unittest

DEMO = Path(__file__).resolve().parent
VALUES = (DEMO / "chart/values.yaml").read_text()


def value(name):
    return re.search(rf"^\s*{name}:\s*(\S+)\s*$", VALUES, re.M).group(1)


INSTALLER_PASSWORD, WORKER_PASSWORD = value("installerPassword"), value("workerPassword")


def render(mode):
    """Rendered documents keyed by (kind, name); helm template is offline."""
    result = subprocess.run(["helm", "template", f"rolling-{mode}", str(DEMO / "chart"), "--set", f"mode={mode}"],
                            text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise AssertionError(result.stderr)
    documents = {}
    for text in re.split(r"^---\s*$", result.stdout, flags=re.M):
        kind = re.search(r"^kind:\s*(\S+)", text, re.M)
        name = re.search(r"^metadata:\n(?:\s+.*\n)*?\s+name:\s*(\S+)", text, re.M)
        if kind and name:
            documents[(kind.group(1), name.group(1))] = text
    return documents


def secret_data(text):
    """The flat stringData mapping of a rendered Secret."""
    block = text.split("stringData:\n", 1)[1]
    data = {}
    for line in block.splitlines():
        match = re.match(r"^\s{2}([A-Z_]+):\s*(.*)$", line)
        if not match:
            break
        data[match.group(1)] = match.group(2).strip('"')
    return data


def hook(text):
    match = re.search(r'helm\.sh/hook:\s*"([^"]+)"', text)
    weight = re.search(r'helm\.sh/hook-weight:\s*"(-?\d+)"', text)
    return (match.group(1) if match else None, int(weight.group(1)) if weight else None)


@unittest.skipUnless(shutil.which("helm"), "helm is required; enter nix develop .#kubernetes")
class ChartCredentialScopes(unittest.TestCase):
    def test_request_secret_holds_no_privileged_credentials(self):
        documents = render("app")
        runtime = secret_data(documents[("Secret", "rolling-app-runtime")])
        self.assertIn("DEMO_DDL", runtime)
        self.assertTrue(runtime["DEMO_DDL"].startswith("postgres://demo_request:"), runtime["DEMO_DDL"])
        self.assertNotIn("TESL_SCHEMA_INSTALLER_DSN", runtime)
        # Role names are public; a privileged password would appear in a DSN or
        # as the connection password.
        self.assertEqual(runtime["DEMO_USER"], "demo_request")
        self.assertNotIn(runtime["DEMO_PASSWORD"], (INSTALLER_PASSWORD, WORKER_PASSWORD))
        for secret in (INSTALLER_PASSWORD, WORKER_PASSWORD):
            self.assertFalse(any(f":{secret}@" in item for item in runtime.values()), "Request Secret carries a privileged password")

    def test_worker_secret_holds_no_installer_dsn(self):
        documents = render("migrator")
        runtime = secret_data(documents[("Secret", "rolling-migrator-runtime")])
        self.assertTrue(runtime["DEMO_DDL"].startswith("postgres://demo_worker:"), runtime["DEMO_DDL"])
        self.assertNotIn("TESL_SCHEMA_INSTALLER_DSN", runtime)
        self.assertFalse(any(f":{INSTALLER_PASSWORD}@" in item or "postgres://postgres:" in item for item in runtime.values()),
                         "Worker Secret carries Installer credentials")
        deployment = documents[("Deployment", "rolling-migrator")]
        self.assertEqual(hook(deployment), (None, None))
        self.assertIn('command: ["/worker.sh"]', deployment)
        self.assertIn("name: rolling-migrator-runtime", deployment)
        self.assertNotIn("schema-install", deployment)
        worker = (DEMO / "worker.sh").read_text()
        self.assertIn("/app --schema worker --json", worker)
        self.assertNotIn("--install", worker)

    def test_installer_job_runs_once_before_the_worker(self):
        documents = render("migrator")
        secret = documents[("Secret", "rolling-migrator-schema-install")]
        job = documents[("Job", "rolling-migrator-schema-install")]
        installer = secret_data(secret)
        self.assertTrue(installer["DEMO_DDL"].startswith(f"postgres://postgres:{INSTALLER_PASSWORD}@"), installer["DEMO_DDL"])
        self.assertNotIn("TESL_SCHEMA_INSTALLER_DSN", installer)
        # Helm runs pre-install/pre-upgrade hooks in weight order and waits for
        # the Job to succeed before it creates or updates the Worker Deployment.
        self.assertEqual(hook(secret), ("pre-install,pre-upgrade", -10))
        self.assertEqual(hook(job), ("pre-install,pre-upgrade", 0))
        self.assertIn("args: [--schema, install, --worker, demo_worker, --request, demo_request, --json]", job)
        self.assertIn("restartPolicy: Never", job)
        self.assertIn("name: rolling-migrator-schema-install", job.split("envFrom:", 1)[1])
        self.assertEqual({kind for kind, _ in documents}, {"Secret", "Deployment", "Job"})

    def test_retirement_hook_runs_after_the_application(self):
        documents = render("app")
        secret = documents[("Secret", "rolling-app-schema-hook")]
        job = documents[("Job", "rolling-app-schema-hook")]
        self.assertEqual(hook(secret), ("post-install,post-upgrade", -10))
        self.assertEqual(hook(job), ("post-install,post-upgrade", 0))
        self.assertIn("args: [--schema, deploy, --json]", job)
        data = secret_data(secret)
        self.assertTrue(data["DEMO_DDL"].startswith("postgres://demo_worker:"), data["DEMO_DDL"])
        self.assertTrue(data["TESL_SCHEMA_INSTALLER_DSN"].startswith("postgres://postgres:"))
        self.assertNotIn(("Job", "rolling-app-schema-install"), documents)

    def test_releases_are_ordered_database_migrator_app(self):
        infra = (DEMO / "infra/main.tf").read_text()
        self.assertIn("depends_on    = [helm_release.database]", infra.split('resource "helm_release" "migrator"', 1)[1].split("resource ", 1)[0])
        self.assertIn("depends_on    = [helm_release.migrator]", infra.split('resource "helm_release" "app"', 1)[1])


if __name__ == "__main__":
    unittest.main()

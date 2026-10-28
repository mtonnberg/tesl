#!/usr/bin/env python3
"""Check the deployment template and the rollout's real process-exit gate."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DeploymentWiring(unittest.TestCase):
    def test_compose_configuration_and_credential_scopes(self):
        with tempfile.TemporaryDirectory(prefix="tesl-compose-") as directory:
            root = Path(directory)
            compose = root / "compose.yml"
            shutil.copyfile(ROOT / "templates/docker/compose.worker.yml.example", compose)
            for role in ("deploy", "worker", "request"):
                (root / f".env.{role}").write_text(f"CREDENTIAL_SCOPE={role}\n")
            result = subprocess.run(["docker", "compose", "-f", str(compose), "config", "--format", "json"],
                                    env=dict(os.environ, TESL_IMAGE="example/tesl:checked-release"), text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            services = json.loads(result.stdout)["services"]
            self.assertEqual(services["schema-deploy"]["command"], ["--schema", "deploy", "--json"])
            for service, role in (("schema-deploy", "deploy"), ("schema-worker", "worker"), ("app", "request")):
                self.assertEqual(services[service]["environment"]["CREDENTIAL_SCOPE"], role)
                self.assertEqual(services[service]["image"], "example/tesl:checked-release")
            for service in ("app", "schema-worker"):
                self.assertEqual(services[service]["depends_on"]["schema-deploy"]["condition"], "service_completed_successfully")

    def test_failed_job_never_starts_new_services(self):
        for failure in (0, 23):
            with self.subTest(job_exit=failure), tempfile.TemporaryDirectory(prefix="tesl-rollout-") as directory:
                root = Path(directory)
                docker = root / "docker"
                docker.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ["CALL_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if "--exit-code-from" in sys.argv:
    sys.exit(int(os.environ["JOB_EXIT"]))
''')
                docker.chmod(0o755)
                log = root / "calls.jsonl"
                compose = root / "project with spaces.yml"
                result = subprocess.run(["sh", str(ROOT / "templates/docker/deploy-worker.sh"), str(compose)],
                                        env=dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"], CALL_LOG=str(log), JOB_EXIT=str(failure)),
                                        text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, failure, result.stderr)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertTrue(all(call[:3] == ["compose", "-f", str(compose)] for call in calls))
                operations = [call[3:] for call in calls]
                stopped = next(i for i, call in enumerate(operations) if call[0] == "stop")
                migration = next(i for i, call in enumerate(operations) if "--exit-code-from" in call)
                self.assertLess(stopped, migration)
                starts = [i for i, call in enumerate(operations) if call[0] == "up" and "-d" in call]
                self.assertEqual(len(starts), 0 if failure else 1)
                if starts:
                    self.assertGreater(starts[0], migration)
                    self.assertIn("--no-deps", operations[starts[0]])


if __name__ == "__main__":
    unittest.main()

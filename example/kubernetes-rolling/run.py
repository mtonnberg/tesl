#!/usr/bin/env python3
"""Build, run and measure a disposable local kind/Helm/OpenTofu rollout."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request

DEMO = Path(__file__).resolve().parent
ROOT = DEMO.parents[1]


def run(args, *, env=None, timeout=600, log=None):
    process = subprocess.Popen([str(arg) for arg in args], env=env, text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        # Include provider/build children: they must not outlive cluster cleanup.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            stdout, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate()
        if log:
            log.write_text(stdout + stderr)
        raise
    result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    if log:
        log.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"{' '.join(map(str, args))}:\n{result.stdout}\n{result.stderr}")
    return result.stdout


def request(url, path, method="GET"):
    with urllib.request.urlopen(urllib.request.Request(url + path, method=method), timeout=5) as response:
        return json.loads(response.read())


def main():
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".tesl-stuff/kubernetes-rolling")
    parser.add_argument("--releases", type=Path, help="reuse releases built with build.py")
    parser.add_argument("--cluster", default="tesl-rolling")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--keep", action="store_true", help="leave this demo's cluster running for inspection")
    args = parser.parse_args()
    output = args.output.absolute()
    if output.exists():
        parser.error("choose a new output directory")
    for tool in ("docker", "kind", "kubectl", "tofu", "helm", "go"):
        if not shutil.which(tool):
            parser.error(f"{tool} is required; enter nix develop .#kubernetes")
    if args.cluster in run(["kind", "get", "clusters"]).splitlines():
        parser.error("the named cluster already exists; choose a new name or remove your old demo explicitly")
    with socket.socket() as available:
        available.bind(("127.0.0.1", args.port))
    output.mkdir(parents=True)
    releases = args.releases.absolute() if args.releases else output / "releases"
    if args.releases is None:
        run([sys.executable, DEMO / "build.py", "--output", releases], timeout=1200, log=output / "build.log")
    for version in (1, 2, 3):
        if not (releases / f"v{version}/app").is_file():
            parser.error(f"missing built V{version} application")
    shutil.copytree(DEMO / "infra", output / "infra")
    shutil.copytree(DEMO / "chart", output / "chart")
    kubeconfig = output / "kubeconfig"
    config = output / "kind.yaml"
    config.write_text(f'''kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerAddress: "127.0.0.1"
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: {args.port}
        listenAddress: "127.0.0.1"
        protocol: TCP
''')
    env = dict(os.environ, KUBECONFIG=str(kubeconfig), TF_IN_AUTOMATION="1")
    namespace = "tesl-rolling"
    url = f"http://127.0.0.1:{args.port}"
    attempted, created, probe, stop, observer = False, False, None, threading.Event(), None
    snapshots, observation_errors = [], []

    def kubectl(*arguments):
        return run(["kubectl", "--kubeconfig", kubeconfig, "-n", namespace, *arguments], env=env, timeout=30)

    def inspect(version):
        value = json.loads(kubectl("exec", "deployment/rolling-database", "--", "psql", "-X", "-U", "postgres", "-d", "rolling_demo", "-Atc", '''
select json_build_object(
 'current',s.current,'minimum',s.min_version,'compatibility',s.compat_floor,
 'jobs',(select coalesce(json_agg(json_build_object('version',schema_version,'payload',payload,'status',status)),'[]') from demo.tesl_jobs),
 'converted',(select count(*) from demo.tesl_row_queue_conversion_receipts where kind='converted'),
 'restamped',(select count(*) from demo.tesl_row_queue_restamps),
 'contracted',(select coalesce(json_agg(version order by version),'[]') from demo.tesl_schema_versions where step='contracted'),
 'columns',(select json_agg(column_name order by ordinal_position) from information_schema.columns where table_schema='demo' and table_name='notes'))
from demo.tesl_schema_state s;
'''))
        (output / f"database-v{version}.json").write_text(json.dumps(value, indent=2) + "\n")
        assert value["current"] == value["minimum"] == value["compatibility"] == version, value
        if version >= 2:
            assert "headline" in value["columns"] and "title" not in value["columns"], value
            assert 2 in value["contracted"], value
        if version == 2:
            # Compatible consumers can also advance a job's stamp on retry;
            # an explicit retirement restamp is not required for every job.
            assert all(job["version"] == 2 and job["payload"]["oldText"] == job["payload"]["id"] for job in value["jobs"]), value
        if version == 3:
            assert value["converted"] > 0 and 3 in value["contracted"], value
            assert all(job["version"] == 3 and job["payload"]["priority"] == 1 and "oldText" not in job["payload"] for job in value["jobs"]), value
        return value

    def observe():
        while not stop.is_set():
            try:
                pods = json.loads(kubectl("get", "pods", "-l", "app=rolling-app", "-o", "json"))
                ready = [pod for pod in pods["items"] if not pod["metadata"].get("deletionTimestamp") and any(
                    condition["type"] == "Ready" and condition["status"] == "True" for condition in pod.get("status", {}).get("conditions", []))]
                snapshots.append({"time": time.time(), "ready": len(ready), "revisions": sorted({pod["metadata"]["annotations"]["demo.tesl/revision"] for pod in ready})})
            except Exception as error:
                observation_errors.append(str(error))
            stop.wait(.5)

    try:
        # This script only creates and modifies its own named local cluster.
        attempted = True
        run(["kind", "create", "cluster", "--name", args.cluster, "--image", "kindest/node:v1.35.0", "--config", config, "--kubeconfig", kubeconfig, "--wait", "120s"], timeout=600, log=output / "kind.log")
        created = True
        run(["kubectl", "--kubeconfig", kubeconfig, "-n", "kube-system", "rollout", "status", "daemonset/kube-proxy", "--timeout=120s"], env=env, timeout=130, log=output / "kube-proxy.log")
        run(["kubectl", "--kubeconfig", kubeconfig, "-n", "kube-system", "rollout", "status", "deployment/coredns", "--timeout=120s"], env=env, timeout=130, log=output / "dns.log")
        run(["tofu", f"-chdir={output / 'infra'}", "init", "-input=false"], env=env, log=output / "tofu-init.log")
        for version in (1, 2, 3):
            context = output / f"image-v{version}"
            context.mkdir()
            for name in ("Dockerfile", "worker.sh"):
                shutil.copyfile(DEMO / name, context / name)
            shutil.copyfile(releases / f"v{version}/app", context / "app")
            image = f"tesl-rolling-demo:{args.cluster}-v{version}"
            run(["docker", "build", "-t", image, context], timeout=600, log=output / f"image-v{version}.log")
            run(["kind", "load", "docker-image", "--name", args.cluster, image], timeout=300)
            values = {"kubeconfig_path": str(kubeconfig), "namespace": namespace, "app_image": image,
                      "revision": version, "schema_version": version, "host_port": args.port}
            (output / "infra/demo.auto.tfvars.json").write_text(json.dumps(values, indent=2) + "\n")
            print(f"Applying V{version}: Installer -> ready schema worker -> rolling app -> retirement", flush=True)
            run(["tofu", f"-chdir={output / 'infra'}", "apply", "-input=false", "-auto-approve"], env=env, timeout=1200, log=output / f"apply-v{version}.log")
            assert request(url, "/health")["release"] == version
            inspect(version)
            if version == 1:
                for number in range(8):
                    request(url, f"/notes/seed-{number}", "POST")
                    request(url, f"/jobs/seed-{number}", "POST")
                assert request(url, "/receipts") == []
                seeded = inspect(1)
                assert len(seeded["jobs"]) >= 8, seeded
                probe = subprocess.Popen([sys.executable, str(DEMO / "probe.py"), "--url", url, "--output", str(output / "availability.json")], env=env)
                observer = threading.Thread(target=observe)
                observer.start()
                time.sleep(2)
        probe.send_signal(signal.SIGTERM)
        code = probe.wait(timeout=15)
        probe = None
        stop.set(); observer.join(timeout=35)
        report = json.loads((output / "availability.json").read_text())
        assert code == 0, report
        assert not observation_errors, observation_errors
        assert snapshots and min(sample["ready"] for sample in snapshots) >= 2, snapshots
        for revisions in (["1", "2"], ["2", "3"]):
            assert any(sample["revisions"] == revisions for sample in snapshots), f"no observed ready-pod overlap: {revisions}"
        # The probe records accepted IDs. All must survive their schema changes.
        notes = request(url, "/notes")
        note_ids = {row["id"] for row in notes}
        assert all(row["headline"] == row["id"] for row in notes), "renamed row values changed"
        assert report["observed_releases"] == [1, 2, 3], report["observed_releases"]
        accepted_notes = set(report["accepted_ids"]["notes"])
        accepted_jobs = set(report["accepted_ids"]["jobs"])
        expected_jobs = accepted_jobs | {f"seed-{number}" for number in range(8)}
        assert accepted_notes | {f"seed-{number}" for number in range(8)} <= note_ids
        request(url, "/deliver", "POST")
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            receipts = {row["id"]: row["text"] for row in request(url, "/receipts")}
            if expected_jobs <= receipts.keys():
                break
            time.sleep(.5)
        assert all(receipts.get(identity) == identity for identity in expected_jobs), "missing or changed job result"
        summary = {"ok": True, "endpoint": url, "cluster": args.cluster,
                   "acceptedNotes": len(accepted_notes), "acceptedJobs": len(accepted_jobs),
                   "completedJobs": len(expected_jobs), "minimumReadyPods": min(sample["ready"] for sample in snapshots),
                   "overlap": [[1, 2], [2, 3]], "availability": "zero failed sampled requests; see availability.json"}
        (output / "result.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2), flush=True)
    finally:
        if probe is not None and probe.poll() is None:
            probe.send_signal(signal.SIGTERM); probe.wait(timeout=15)
        stop.set()
        if observer is not None:
            observer.join(timeout=35)
            (output / "pod-readiness.json").write_text(json.dumps({"samples": snapshots, "errors": observation_errors}, indent=2) + "\n")
        if created:
            for name, command in (("pods", ["get", "pods", "-o", "wide"]), ("events", ["get", "events", "--sort-by=.lastTimestamp"])):
                try:
                    (output / f"{name}.log").write_text(kubectl(*command))
                except Exception as error:
                    (output / f"{name}.log").write_text(str(error))
            if args.keep:
                print(f"Cluster retained. Inspect with KUBECONFIG={kubeconfig}; delete with kind delete cluster --name {args.cluster} --kubeconfig {kubeconfig}", flush=True)
        if attempted and (not args.keep or not created):
            run(["kind", "delete", "cluster", "--name", args.cluster, "--kubeconfig", kubeconfig], env=env, timeout=120)


if __name__ == "__main__":
    main()

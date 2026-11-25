#!/usr/bin/env python3
"""Publish one exact source revision as a GitHub Release, or do nothing.

Called by .github/workflows/release.yml whenever CI or Native portability
finishes. For the commit (SHA) that run tested, it:

1. Finds the latest push-event runs of BOTH workflows for that SHA in this
   repository. If either is still running it exits quietly; the other
   workflow's completion calls it again. If either failed, nothing publishes.
2. Downloads the native archives, setup executable, evidence and release plan
   from the Native portability run, and verifies every file's GitHub
   attestation (signed by that workflow, for that SHA and ref).
3. Builds the release catalog (scripts/release_catalog.py) with receipts for
   every mandatory gate and refuses to continue unless it is publish-eligible.
4. Creates the release as a draft, uploads every asset, checks the uploaded
   digests, then publishes it. A main commit becomes a prerelease named
   `v<version>-dev.<timestamp>.g<sha>`; a `v<version>` tag becomes the stable
   release and GitHub's "latest". Re-running for an already published release
   is a no-op when its assets match, and an error when they differ.
5. For main commits, moves the continuous-channel pointer (`continuous.json`
   on the `release-channel` branch) with a fast-forward-only push, so an older
   commit that finishes late never replaces a newer one.

Nothing here builds or changes artifact bytes; it only checks and publishes
what the native workflow attested.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

import release_catalog as release


CI_WORKFLOW = ".github/workflows/ci.yml"
NATIVE_WORKFLOW = ".github/workflows/native-parity.yml"
CHANNEL_BRANCH = "release-channel"
CHANNEL_FILE = "continuous.json"


class Skip(Exception):
    """Nothing to publish yet, or nothing to publish for this revision."""


class GitHub:
    """Thin wrapper over the `gh` CLI; replaced by a fake in tests."""

    def __init__(self, repository):
        self.repository = repository

    def gh(self, *arguments, capture=True, check=True):
        result = subprocess.run(["gh", *arguments], check=False, capture_output=capture, text=True, timeout=1800)
        if check and result.returncode != 0:
            raise RuntimeError(f"gh {' '.join(arguments[:2])} failed: {(result.stderr or '').strip()}")
        return result

    def api(self, path, method="GET", fields=None, allow_missing=False):
        arguments = ["api", "--method", method, path]
        for key, value in (fields or {}).items():
            arguments += ["-F" if isinstance(value, bool) else "-f", f"{key}={str(value).lower() if isinstance(value, bool) else value}"]
        result = self.gh(*arguments, check=False)
        if result.returncode != 0:
            if allow_missing and "HTTP 404" in (result.stderr or ""):
                return None
            raise RuntimeError(f"GitHub API {method} {path} failed: {(result.stderr or '').strip()}")
        return json.loads(result.stdout) if result.stdout.strip() else None

    def runs_for(self, sha):
        return self.api(f"repos/{self.repository}/actions/runs?head_sha={sha}&event=push&per_page=100")["workflow_runs"]

    def download(self, run_id, destination, *selectors):
        self.gh("run", "download", str(run_id), "-R", self.repository, "-D", str(destination), *selectors, capture=False)

    def verify_attestation(self, path, ref, sha):
        self.gh("attestation", "verify", str(path), "--repo", self.repository,
                "--signer-workflow", f"{self.repository}/{NATIVE_WORKFLOW}", "--source-ref", ref,
                "--source-digest", sha, "--signer-digest", sha, "--deny-self-hosted-runners")

    def release(self, tag):
        return self.api(f"repos/{self.repository}/releases/tags/{tag}", allow_missing=True)

    def draft_releases(self, tag):
        rows = self.api(f"repos/{self.repository}/releases?per_page=100")
        return [row for row in rows if row.get("draft") and row.get("tag_name") == tag]

    def delete_release(self, release_id):
        self.api(f"repos/{self.repository}/releases/{release_id}", method="DELETE")

    def create_draft(self, tag, sha, title, notes, prerelease, assets, create_tag):
        arguments = ["release", "create", tag, "-R", self.repository, "--draft", "--title", title,
                     "--notes-file", str(notes), *(["--target", sha] if create_tag else ["--verify-tag"])]
        if prerelease:
            arguments.append("--prerelease")
        self.gh(*arguments, *map(str, assets), capture=False)
        rows = self.draft_releases(tag)
        if len(rows) != 1:
            raise RuntimeError(f"expected one draft release for {tag}, found {len(rows)}")
        return rows[0]

    def assets(self, release_id):
        return self.api(f"repos/{self.repository}/releases/{release_id}/assets?per_page=100")

    def publish(self, release_id, latest):
        self.api(f"repos/{self.repository}/releases/{release_id}", method="PATCH",
                 fields={"draft": False, "make_latest": "true" if latest else "false"})


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def latest_run(runs, path, repository):
    rows = [run for run in runs if run.get("path") == path and run.get("event") == "push"
            and run.get("repository", {}).get("full_name") == repository
            and run.get("head_repository", {}).get("full_name") == repository]
    if not rows:
        raise Skip(f"no push run of {path} for this commit yet")
    return max(rows, key=lambda run: (run["run_number"], run.get("run_attempt", 1)))


def source_ref(run, base_version):
    """Only main and the exact `v<base version>` tag are publishable refs."""
    branch = run.get("head_branch")
    if branch == "main":
        return "refs/heads/main"
    if branch == "v" + base_version:
        return "refs/tags/" + branch
    raise Skip(f"ref {branch!r} is not a release ref")


def find_runs(github, sha):
    runs = github.runs_for(sha)
    ci, native = (latest_run(runs, path, github.repository) for path in (CI_WORKFLOW, NATIVE_WORKFLOW))
    for run in (ci, native):
        if run["status"] != "completed":
            raise Skip(f"{run['path']} run {run['id']} is still {run['status']}")
        if run["conclusion"] != "success":
            raise Skip(f"{run['path']} run {run['id']} concluded {run['conclusion']}; nothing is published")
    if ci["head_branch"] != native["head_branch"]:
        raise Skip("CI and native runs tested different refs")
    return ci, native


def receipt(gate, target, run, plan, source, subjects):
    return {"verification": "verified", "result": "passed", "repository": source["repository"],
            "workflow": plan["releasePolicy"]["gateWorkflows"][gate], "run_id": str(run["id"]),
            "run_attempt": int(run.get("run_attempt", 1)), "source_revision": plan["sourceRevision"],
            "toolchain_version": plan["toolchainVersion"], "event": source["event"], "ref": source["ref"],
            "inputs": release.expected_inputs(plan, target), "subjects": subjects}


def records_for(plan, artifacts, ci, native, ref, repository):
    """Receipts are issued only after the API and attestation checks above."""
    source = {"repository": repository, "revision": plan["sourceRevision"], "ref": ref, "event": "push",
              "authorized": True, "clean": True}
    records = {"version": 1, "source": source, "checks": {},
               "targets": {target: {"parity": f"native-evidence-{target}/checks.json",
                                    "distribution": f"native-candidate-{target}/distribution-checks.json"}
                           for target in release.TARGETS}}
    # A first pass inventories the real bytes; receipts then name those digests.
    inventory = release.build_catalog(plan, artifacts, records)
    # Every gate the catalog evaluates. The catalog itself still decides from the
    # per-target evidence (OS, network isolation, signing policy) whether each passed.
    for gate in sorted(set(plan["releasePolicy"]["mandatoryChecks"]) | release.EXTRA_GATES):
        run = ci if gate == "authoritative-gate" else native
        scopes = ["all"] if gate == "authoritative-gate" else sorted(release.TARGETS)
        records["checks"][gate] = {target: receipt(gate, target, run, plan, source, release.expected_subjects(
            gate, target, inventory["targets"], inventory["input_files"])) for target in scopes}
    return records


def check_plan(plan, sha, ref):
    release.validate_plan(plan)
    if plan["sourceRevision"] != sha:
        raise ValueError("downloaded release plan is for a different commit")
    channel = plan["release"]["channel"]
    expected = "stable" if ref.startswith("refs/tags/") else "continuous"
    if channel != expected or (expected == "stable" and ref != "refs/tags/" + plan["release"]["tag"]):
        raise ValueError(f"release plan channel {channel!r} does not match {ref}")


def release_assets(catalog, artifacts, extra):
    paths = [artifacts / path for path in sorted(catalog["input_files"])
             if Path(path).name in catalog["assets"]]
    names = [path.name for path in paths] + [path.name for path in extra]
    if len(names) != len(set(names)) or len(paths) != len(catalog["assets"]):
        raise ValueError("release asset names are not unique or incomplete")
    return paths + list(extra)


def expected_digests(paths):
    return {path.name: sha256(path) for path in paths}


def uploaded_digests(rows):
    result = {}
    for row in rows:
        digest = row.get("digest") or ""
        if not digest.startswith("sha256:"):
            raise RuntimeError(f"GitHub did not report a digest for asset {row.get('name')}")
        result[row["name"]] = digest.removeprefix("sha256:")
    return result


def notes(catalog, plan, ci, native):
    stable = catalog["channel"] == "stable"
    lines = [f"Tesl {catalog['toolchain_version']} built from {catalog['source_revision']}.", "",
             "Stable release." if stable else
             "Continuous build of `main`. It passed the full CI gate and the native packaging gate, "
             "but it is not a stable release.", "",
             "Supported systems (each tested on the oldest version listed):", ""]
    for row in plan["candidates"]:
        lines.append(f"- `{row['target']}`: {row['baseline']}")
    lines += ["", "Windows downloads are unsigned and macOS binaries are ad-hoc signed; see INSTALL.md "
              "for checksum and attestation verification.", "",
              f"CI run: https://github.com/{catalog['source']['repository']}/actions/runs/{ci['id']}",
              f"Native run: https://github.com/{catalog['source']['repository']}/actions/runs/{native['id']}"]
    return "\n".join(lines) + "\n"


def publish_release(github, catalog, sha, paths, notes_path):
    """Return the published release; idempotent for identical assets."""
    tag, stable = catalog["release_tag"], catalog["channel"] == "stable"
    wanted = expected_digests(paths)
    existing = github.release(tag)
    if existing is not None and not existing.get("draft"):
        if uploaded_digests(github.assets(existing["id"])) != wanted:
            raise RuntimeError(f"release {tag} already exists with different assets")
        return existing, False
    # A draft left by an interrupted run is not visible to users; replace it.
    for draft in github.draft_releases(tag):
        github.delete_release(draft["id"])
    draft = github.create_draft(tag, sha, f"Tesl {catalog['toolchain_version']}", notes_path,
                                prerelease=not stable, assets=paths, create_tag=not stable)
    if uploaded_digests(github.assets(draft["id"])) != wanted:
        github.delete_release(draft["id"])
        raise RuntimeError("uploaded assets differ from the verified files; draft deleted")
    github.publish(draft["id"], latest=stable)
    return draft, True


def git(*arguments, input_text=None, root=None):
    result = subprocess.run(["git", *arguments], check=True, capture_output=True, text=True,
                            input=input_text, cwd=root, timeout=600)
    return result.stdout.strip()


def main_history(root):
    git("fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main", root=root)
    head = git("rev-parse", "refs/remotes/origin/main", root=root)
    parents = {}
    for line in git("rev-list", "--parents", head, root=root).splitlines():
        commit, *rest = line.split()
        parents[commit] = rest
    return head, parents


def current_pointer(root, repository):
    """Return (pointer or None, remote commit or None) for the channel branch."""
    found = subprocess.run(["git", "ls-remote", "origin", "refs/heads/" + CHANNEL_BRANCH], check=True,
                           capture_output=True, text=True, cwd=root, timeout=300).stdout.split()
    if not found:
        return None, None
    commit = found[0]
    git("fetch", "--quiet", "origin", commit, root=root)
    return json.loads(git("show", f"{commit}:{CHANNEL_FILE}", root=root)), commit


def push_pointer(root, pointer, parent):
    """Fast-forward-only push: fails if another publisher moved the branch."""
    blob = git("hash-object", "-w", "--stdin", input_text=json.dumps(pointer, indent=2, sort_keys=True) + "\n", root=root)
    tree = git("mktree", input_text=f"100644 blob {blob}\t{CHANNEL_FILE}\n", root=root)
    message = f"Continuous channel: {pointer['release_tag']}"
    commit = git("commit-tree", tree, *(["-p", parent] if parent else []), "-m", message, root=root)
    git("push", "--quiet", "origin", f"{commit}:refs/heads/{CHANNEL_BRANCH}", root=root)
    return commit


def advance_channel(root, repository, catalog, attempts=3):
    publication = {"verified": True, "published": True, "repository": repository,
                   "release_tag": catalog["release_tag"], "source_revision": catalog["source_revision"],
                   "catalog_sha256": release.json_hash(catalog)}
    for attempt in range(attempts):
        head, parents = main_history(root)
        history = {"verified": True, "repository": repository, "ref": "refs/heads/main", "head": head, "parents": parents}
        current, remote = current_pointer(root, repository)
        decision = release.channel_decision(catalog, current, publication, history, head)
        if not decision["advance"]:
            return decision
        try:
            push_pointer(root, decision["pointer"], remote)
            return decision
        except subprocess.CalledProcessError:
            if attempt == attempts - 1:
                raise
    raise AssertionError("unreachable")


def run(github, sha, workspace, root):
    ci, native = find_runs(github, sha)
    workspace = Path(workspace)
    plan_dir, provenance_dir, artifacts = (workspace / name for name in ("plan", "provenance", "artifacts"))
    github.download(native["id"], plan_dir, "-n", "native-release-plan")
    plan_path = plan_dir / "native-release-plan.json"
    plan = release.read_json(plan_path)
    ref = source_ref(native, plan["release"]["baseVersion"])
    check_plan(plan, sha, ref)
    github.download(native["id"], artifacts, "-p", "native-candidate-*", "-p", "native-evidence-*")
    github.download(native["id"], provenance_dir, "-n", "native-provenance")
    build_inputs = provenance_dir / "native-build-inputs.json"
    for path in sorted(artifacts.rglob("*")) + [plan_path, build_inputs]:
        if path.is_file():
            github.verify_attestation(path, ref, sha)
    records = records_for(plan, artifacts, ci, native, ref, github.repository)
    catalog = release.build_catalog(plan, artifacts, records)
    if not catalog["eligibility"]["publish_eligible"]:
        raise RuntimeError("release is not eligible: " + "; ".join(catalog["eligibility"]["blockers"]))
    version = catalog["toolchain_version"]
    catalog_path = workspace / f"tesl-{version}-release-catalog.json"
    release.write_immutable(catalog_path, catalog)
    extras = [catalog_path]
    for source, name in ((plan_path, f"tesl-{version}-release-plan.json"),
                         (build_inputs, f"tesl-{version}-build-inputs.json")):
        target = workspace / name
        target.write_bytes(source.read_bytes())
        extras.append(target)
    paths = release_assets(catalog, artifacts, extras)
    notes_path = workspace / "notes.md"
    notes_path.write_text(notes(catalog, plan, ci, native), encoding="utf-8")
    published, created = publish_release(github, catalog, sha, paths, notes_path)
    result = {"tag": catalog["release_tag"], "created": created, "channel": catalog["channel"]}
    if catalog["channel"] == "continuous":
        result["pointer"] = advance_channel(root, github.repository, catalog)["reason"]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    args = parser.parse_args()
    if not args.repository or not release.SHA.fullmatch(args.sha):
        parser.error("a repository and a full commit SHA are required")
    root = Path(__file__).resolve().parent.parent
    try:
        with tempfile.TemporaryDirectory(prefix="tesl-release-") as workspace:
            print(json.dumps(run(GitHub(args.repository), args.sha, workspace, root), sort_keys=True))
    except Skip as reason:
        print(f"No release: {reason}")


if __name__ == "__main__":
    main()

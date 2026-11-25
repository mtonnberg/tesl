"""Publishing: waits for both gates, never publishes changed or partial bytes,
retries idempotently, and never lets a late older build move the channel."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import release_publish as publish
import test_release_catalog as fixtures


REPOSITORY = "mtonnberg/tesl"


def run_row(path, sha, number=10, status="completed", conclusion="success", branch="main", attempt=1,
            repository=REPOSITORY):
    return {"id": number * 100 + attempt, "path": path, "event": "push", "head_sha": sha, "head_branch": branch,
            "run_number": number, "run_attempt": attempt, "status": status, "conclusion": conclusion,
            "repository": {"full_name": REPOSITORY}, "head_repository": {"full_name": repository}}


class FakeGitHub:
    def __init__(self, fixture, sha, runs=None):
        self.repository = REPOSITORY
        self.fixture, self.sha = fixture, sha
        self.runs = runs if runs is not None else [run_row(publish.CI_WORKFLOW, sha), run_row(publish.NATIVE_WORKFLOW, sha)]
        self.attested, self.releases, self.next_id = [], {}, 1
        self.corrupt_upload = False

    def runs_for(self, sha):
        return [row for row in self.runs if row["head_sha"] == sha]

    def download(self, run_id, destination, *selectors):
        destination = Path(destination)
        destination.mkdir(parents=True, exist_ok=True)
        if selectors == ("-n", "native-release-plan"):
            (destination / "native-release-plan.json").write_bytes(fixtures.release.canonical(self.fixture.plan))
        elif selectors == ("-n", "native-provenance"):
            (destination / "native-build-inputs.json").write_text("{}\n")
        else:
            shutil.copytree(self.fixture.artifacts, destination, dirs_exist_ok=True)

    def verify_attestation(self, path, ref, sha):
        self.attested.append((Path(path).name, ref, sha))

    def release(self, tag):
        row = self.releases.get(tag)
        return None if row is None or row["draft"] else row

    def draft_releases(self, tag):
        row = self.releases.get(tag)
        return [row] if row is not None and row["draft"] else []

    def delete_release(self, release_id):
        self.releases = {tag: row for tag, row in self.releases.items() if row["id"] != release_id}

    def create_draft(self, tag, sha, title, notes, prerelease, assets, create_tag):
        digests = {}
        for path in assets:
            content = Path(path).read_bytes() + (b"!" if self.corrupt_upload else b"")
            digests[Path(path).name] = "sha256:" + hashlib.sha256(content).hexdigest()
        row = {"id": self.next_id, "tag_name": tag, "draft": True, "prerelease": prerelease,
               "create_tag": create_tag, "assets": digests, "latest": None}
        self.next_id += 1
        self.releases[tag] = row
        return row

    def assets(self, release_id):
        row = next(row for row in self.releases.values() if row["id"] == release_id)
        return [{"name": name, "digest": digest} for name, digest in row["assets"].items()]

    def publish(self, release_id, latest):
        row = next(row for row in self.releases.values() if row["id"] == release_id)
        row.update(draft=False, latest=latest)


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.ReleaseCatalogTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        # Lay the fixture out exactly as `gh run download -p` does.
        for target in fixtures.release.TARGETS:
            folder = self.fixture.artifacts / f"native-candidate-{target}"
            (self.fixture.artifacts / target).rename(folder)
            evidence = self.fixture.artifacts / f"native-evidence-{target}"
            evidence.mkdir()
            (folder / "checks.json").rename(evidence / "checks.json")
            self.fixture.records["targets"][target] = {"parity": f"native-evidence-{target}/checks.json",
                                                       "distribution": f"native-candidate-{target}/distribution-checks.json"}
        self.sha = self.fixture.plan["sourceRevision"]
        self.workspace = Path(self.fixture.root) / "workspace"
        self.channel = []
        self.repo_root = Path(self.fixture.root)

    def publish(self, github, channel_result="newer-verified-main-revision"):
        original = publish.advance_channel
        publish.advance_channel = lambda root, repository, catalog: (self.channel.append(catalog["release_tag"]),
                                                                    {"reason": channel_result})[1]
        try:
            shutil.rmtree(self.workspace, ignore_errors=True)
            self.workspace.mkdir()
            return publish.run(github, self.sha, self.workspace, self.repo_root)
        finally:
            publish.advance_channel = original

    def test_complete_main_build_becomes_a_prerelease_and_moves_the_channel(self):
        github = FakeGitHub(self.fixture, self.sha)
        result = self.publish(github)
        tag = self.fixture.plan["release"]["tag"]
        self.assertEqual(result, {"tag": tag, "created": True, "channel": "continuous",
                                  "pointer": "newer-verified-main-revision"})
        row = github.releases[tag]
        self.assertFalse(row["draft"])
        self.assertTrue(row["prerelease"])
        self.assertTrue(row["create_tag"])
        self.assertFalse(row["latest"])
        self.assertEqual(self.channel, [tag])
        # 12 archive/setup/checksum assets plus catalog, plan and build inputs.
        self.assertEqual(len(row["assets"]), 15)
        self.assertFalse(any(name.endswith("checks.json") for name in row["assets"]))
        attested = {name for name, _, _ in github.attested}
        self.assertIn("native-release-plan.json", attested)
        self.assertIn("native-build-inputs.json", attested)
        self.assertIn("distribution-checks.json", attested)
        self.assertTrue(all(ref == "refs/heads/main" and sha == self.sha for _, ref, sha in github.attested))

    def test_waits_while_either_workflow_is_running_and_skips_failures(self):
        for ci, native, message in (({"status": "in_progress"}, {}, "still in_progress"),
                                    ({}, {"status": "queued"}, "still queued"),
                                    ({"conclusion": "failure"}, {}, "concluded failure"),
                                    ({}, {"conclusion": "cancelled"}, "concluded cancelled")):
            with self.subTest(message=message):
                runs = [run_row(publish.CI_WORKFLOW, self.sha, **ci), run_row(publish.NATIVE_WORKFLOW, self.sha, **native)]
                github = FakeGitHub(self.fixture, self.sha, runs)
                with self.assertRaisesRegex(publish.Skip, message):
                    self.publish(github)
                self.assertEqual(github.releases, {})

    def test_latest_rerun_attempt_decides(self):
        runs = [run_row(publish.CI_WORKFLOW, self.sha, conclusion="failure"),
                run_row(publish.CI_WORKFLOW, self.sha, attempt=2),
                run_row(publish.NATIVE_WORKFLOW, self.sha)]
        self.assertTrue(self.publish(FakeGitHub(self.fixture, self.sha, runs))["created"])

    def test_fork_pr_branch_and_missing_runs_never_publish(self):
        cases = {"fork": [run_row(publish.CI_WORKFLOW, self.sha, repository="someone/tesl"),
                          run_row(publish.NATIVE_WORKFLOW, self.sha, repository="someone/tesl")],
                 "branch": [run_row(publish.CI_WORKFLOW, self.sha, branch="feature"),
                            run_row(publish.NATIVE_WORKFLOW, self.sha, branch="feature")],
                 "other tag": [run_row(publish.CI_WORKFLOW, self.sha, branch="v9.9.9"),
                               run_row(publish.NATIVE_WORKFLOW, self.sha, branch="v9.9.9")],
                 "missing": [run_row(publish.NATIVE_WORKFLOW, self.sha)]}
        for name, runs in cases.items():
            with self.subTest(name=name):
                github = FakeGitHub(self.fixture, self.sha, runs)
                with self.assertRaises(publish.Skip):
                    self.publish(github)
                self.assertEqual(github.releases, {})

    def test_a_failed_attestation_stops_before_anything_is_created(self):
        github = FakeGitHub(self.fixture, self.sha)
        def reject(path, ref, sha):
            if Path(path).suffix == ".zip":
                raise RuntimeError("gh attestation verify failed: no matching attestation")
        github.verify_attestation = reject
        with self.assertRaisesRegex(RuntimeError, "attestation"):
            self.publish(github)
        self.assertEqual(github.releases, {})

    def test_failed_architecture_evidence_is_never_published(self):
        self.fixture.change("darwin-arm64", "distribution", lambda row: row.update(minimum_os_runtime="not-established"))
        github = FakeGitHub(self.fixture, self.sha)
        with self.assertRaisesRegex(RuntimeError, "not eligible: minimum-os-runtime/darwin-arm64"):
            self.publish(github)
        self.assertEqual(github.releases, {})

    def test_plan_for_a_different_commit_is_rejected(self):
        github = FakeGitHub(self.fixture, "b" * 40, [run_row(publish.CI_WORKFLOW, "b" * 40),
                                                       run_row(publish.NATIVE_WORKFLOW, "b" * 40)])
        self.sha = "b" * 40
        with self.assertRaisesRegex(ValueError, "different commit"):
            self.publish(github)

    def test_duplicate_run_is_a_no_op_and_changed_bytes_are_refused(self):
        github = FakeGitHub(self.fixture, self.sha)
        self.publish(github)
        again = self.publish(github)
        self.assertFalse(again["created"])
        tag = self.fixture.plan["release"]["tag"]
        archive = next(self.fixture.artifacts.glob("native-candidate-linux-amd64/*.tar.gz"))
        digest = self.fixture.asset(archive, b"rebuilt with different bytes")
        self.fixture.change("linux-amd64", "distribution", lambda row: row.update(sha256=digest))
        with self.assertRaisesRegex(RuntimeError, "already exists with different assets"):
            self.publish(github)
        self.assertEqual(len(github.releases), 1)
        self.assertFalse(github.releases[tag]["draft"])

    def test_corrupt_upload_deletes_the_draft_and_publishes_nothing(self):
        github = FakeGitHub(self.fixture, self.sha)
        github.corrupt_upload = True
        with self.assertRaisesRegex(RuntimeError, "uploaded assets differ"):
            self.publish(github)
        self.assertEqual(github.releases, {})
        self.assertEqual(self.channel, [])

    def test_draft_left_by_an_interrupted_run_is_replaced(self):
        github = FakeGitHub(self.fixture, self.sha)
        tag = self.fixture.plan["release"]["tag"]
        github.releases[tag] = {"id": 99, "tag_name": tag, "draft": True, "assets": {"partial": "sha256:00"}}
        github.next_id = 100
        self.assertTrue(self.publish(github)["created"])
        self.assertEqual(github.releases[tag]["id"], 100)
        self.assertFalse(github.releases[tag]["draft"])

    def test_stable_tag_becomes_latest_without_moving_the_continuous_channel(self):
        self.fixture.plan = fixtures.plan_for(stable=True)
        for target in fixtures.release.TARGETS:
            def rename(row):
                row["toolchain_version"] = self.fixture.plan["toolchainVersion"]
            for kind, folder in (("checks.json", f"native-evidence-{target}"),
                                 ("distribution-checks.json", f"native-candidate-{target}")):
                path = self.fixture.artifacts / folder / kind
                row = json.loads(path.read_text())
                rename(row)
                old = row.get("archive")
                if old:
                    new = self.fixture.plan["payloads"][target]["archiveName"]
                    (self.fixture.artifacts / folder / old).rename(self.fixture.artifacts / folder / new)
                    (self.fixture.artifacts / folder / (old + ".sha256")).unlink()
                    row["archive"] = new
                    row["sha256"] = self.fixture.asset(self.fixture.artifacts / folder / new,
                                                       (self.fixture.artifacts / folder / new).read_bytes())
                    if row.get("setup"):
                        setup_old = row["setup"]["archive"]
                        setup_new = self.fixture.plan["payloads"][target]["installerName"]
                        (self.fixture.artifacts / folder / setup_old).rename(self.fixture.artifacts / folder / setup_new)
                        (self.fixture.artifacts / folder / (setup_old + ".sha256")).unlink()
                        self.fixture.asset(self.fixture.artifacts / folder / setup_new,
                                           (self.fixture.artifacts / folder / setup_new).read_bytes())
                        row["setup"].update(archive=setup_new, embedded_archive_sha256=row["sha256"])
                self.fixture.write_json(path, row)
        tag = self.fixture.plan["release"]["tag"]
        runs = [run_row(publish.CI_WORKFLOW, self.sha, branch=tag), run_row(publish.NATIVE_WORKFLOW, self.sha, branch=tag)]
        github = FakeGitHub(self.fixture, self.sha, runs)
        result = self.publish(github)
        self.assertEqual(result, {"tag": "v0.3.1", "created": True, "channel": "stable"})
        row = github.releases["v0.3.1"]
        self.assertTrue(row["latest"])
        self.assertFalse(row["prerelease"])
        self.assertFalse(row["create_tag"])
        self.assertEqual(self.channel, [])

    def test_continuous_plan_on_a_tag_ref_is_rejected(self):
        tag = "v" + self.fixture.plan["release"]["baseVersion"]
        runs = [run_row(publish.CI_WORKFLOW, self.sha, branch=tag), run_row(publish.NATIVE_WORKFLOW, self.sha, branch=tag)]
        with self.assertRaisesRegex(ValueError, "does not match refs/tags"):
            self.publish(FakeGitHub(self.fixture, self.sha, runs))


class ChannelPushTests(unittest.TestCase):
    """The pointer lives on a branch; pushes are fast-forward only (compare-and-set)."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="release channel ")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.origin, self.work = root / "origin.git", root / "work"
        environment = ["-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false"]
        self.git = lambda *args, cwd=None: subprocess.run(["git", *environment, *args], cwd=cwd or self.work, check=True,
                                                          capture_output=True, text=True).stdout.strip()
        subprocess.run(["git", "init", "--quiet", "--bare", "-b", "main", str(self.origin)], check=True)
        subprocess.run(["git", "init", "--quiet", "-b", "main", str(self.work)], check=True)
        self.git("remote", "add", "origin", str(self.origin))
        self.commits = []
        for index in range(3):
            self.git("commit", "--quiet", "--allow-empty", "-m", f"commit {index}")
            self.commits.append(self.git("rev-parse", "HEAD"))
        self.git("push", "--quiet", "origin", "main")
        self.original_git = publish.git
        publish.git = lambda *args, input_text=None, root=None: subprocess.run(
            ["git", *environment, *args], check=True, capture_output=True, text=True, input=input_text,
            cwd=root).stdout.strip()
        self.addCleanup(setattr, publish, "git", self.original_git)

    def catalog(self, revision):
        plan = fixtures.plan_for(revision=revision)
        return {"channel": "continuous", "eligibility": {"publish_eligible": True}, "source_revision": revision,
                "release_tag": plan["release"]["tag"], "source": {"repository": REPOSITORY}}

    def pointer(self):
        self.git("fetch", "--quiet", "origin", publish.CHANNEL_BRANCH)
        return json.loads(self.git("show", f"FETCH_HEAD:{publish.CHANNEL_FILE}"))

    def test_first_publish_creates_branch_then_newer_advances_and_older_late_does_not(self):
        middle, newest, oldest = self.commits[1], self.commits[2], self.commits[0]
        self.assertEqual(publish.advance_channel(self.work, REPOSITORY, self.catalog(middle))["reason"],
                         "newer-verified-main-revision")
        self.assertEqual(self.pointer()["source_revision"], middle)
        self.assertEqual(publish.advance_channel(self.work, REPOSITORY, self.catalog(newest))["reason"],
                         "newer-verified-main-revision")
        self.assertEqual(publish.advance_channel(self.work, REPOSITORY, self.catalog(oldest))["reason"],
                         "older-release-finished-late")
        self.assertEqual(publish.advance_channel(self.work, REPOSITORY, self.catalog(newest))["reason"],
                         "already-current")
        self.assertEqual(self.pointer()["source_revision"], newest)

    def test_commit_outside_main_never_moves_the_channel(self):
        self.git("checkout", "--quiet", "-b", "side", self.commits[0])
        self.git("commit", "--quiet", "--allow-empty", "-m", "side")
        side = self.git("rev-parse", "HEAD")
        with self.assertRaisesRegex(ValueError, "not in verified main history"):
            publish.advance_channel(self.work, REPOSITORY, self.catalog(side))

    def test_concurrent_publisher_moving_the_branch_forces_a_retry_not_an_overwrite(self):
        oldest, ours, racer = self.commits
        publish.advance_channel(self.work, REPOSITORY, self.catalog(oldest))
        real_push = publish.push_pointer
        calls = []

        def racing_push(root, pointer, parent):
            if not calls:
                # Another publisher advances to a newer commit between our read and our push.
                newer = self.catalog(racer)
                real_push(root, {**pointer, "source_revision": racer, "release_tag": newer["release_tag"]}, parent)
            calls.append(pointer["source_revision"])
            return real_push(root, pointer, parent)
        publish.push_pointer = racing_push
        self.addCleanup(setattr, publish, "push_pointer", real_push)
        decision = publish.advance_channel(self.work, REPOSITORY, self.catalog(ours))
        self.assertEqual(calls, [ours])  # the stale push failed; the retry did not push again
        self.assertEqual(decision["reason"], "older-release-finished-late")
        self.assertEqual(self.pointer()["source_revision"], racer)

if __name__ == "__main__":
    unittest.main()

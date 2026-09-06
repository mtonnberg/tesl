"""Reject evidence that could otherwise turn a broken tutorial into a success."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("content", ROOT / "scripts/content.py")
content = importlib.util.module_from_spec(spec)
spec.loader.exec_module(content)


class ContentTests(unittest.TestCase):
    def setUp(self):
        self.catalog = json.loads((ROOT / "content/catalog.json").read_text())
        self.example = self.catalog["examples"][0]
        self.source = (ROOT / self.example["source"]).read_text()
        self.broken = content.broken_source(self.source, self.example)
        self.expected = self.example["broken"]["diagnostic"]
        self.bad = {"version": 1, "ok": False, "diagnostics": [{
            "code": "V001", "severity": "error",
            "message": " ".join(self.expected["message_contains"]),
            "line": self.broken.splitlines().index(self.expected["at_line"])}]}

    def test_catalog_and_exact_repair(self):
        content.validate_catalog(self.catalog, ROOT)
        restored = content.broken_source(self.broken, {"broken": {"region": "repair",
            "replacement": content.regions(self.source)["repair"]["text"]}})
        self.assertEqual(restored, self.source)

    def test_region_structure(self):
        for source in ("# content:start a\n", "# content:end a\n",
                       "# content:start a\n# content:start b\n",
                       "# content:start a\n# content:end b\n",
                       "# content:start a\n# content:end a\n" * 2):
            with self.subTest(source=source), self.assertRaises(content.ContentError):
                content.regions(source)

    def test_expected_failure_is_specific(self):
        content.verify_context(self.bad, 1, self.expected, self.broken)
        mutations = [("code", "P001"), ("message", "unrelated V001 error"),
                     ("line", 0), ("severity", "warning")]
        for key, value in mutations:
            changed = copy.deepcopy(self.bad)
            changed["diagnostics"][0][key] = value
            with self.subTest(key=key), self.assertRaises(content.ContentError):
                content.verify_context(changed, 1, self.expected, self.broken)
        for rc in (0, 2, -9):
            with self.subTest(rc=rc), self.assertRaises(content.ContentError):
                content.verify_context(self.bad, rc, self.expected, self.broken)
        with self.assertRaises(content.ContentError):
            content.verify_context({"version": 1, "ok": True, "diagnostics": []}, 0,
                                   self.expected, self.broken)

    def test_repair_cannot_have_remaining_obligations(self):
        clean = {"version": 1, "ok": True, "diagnostics": [], "proof_obligations": []}
        content.verify_context(clean, 0)
        clean["proof_obligations"] = [{"code": "V001"}]
        with self.assertRaises(content.ContentError):
            content.verify_context(clean, 0)

    def test_runtime_requires_actual_execution(self):
        events = [{"Action": "output", "Output": "TESL_GO_TESTS_STARTED\n"},
                  {"Action": "run", "Test": "TestTesl0"},
                  {"Action": "pass", "Test": "TestTesl0"}, {"Action": "pass"}]
        encode = lambda items: "\n".join(json.dumps(e) for e in items)
        content.verify_go_events(encode(events), 0, ["boundary"])
        variants = [[], events[1:], events[:2],
                    events + [{"Action": "skip", "Test": "TestTesl0"}],
                    events + [{"Action": "fail"}],
                    events + [{"Action": "run", "Test": "TestTesl1"}]]
        for variant in variants:
            with self.subTest(events=variant), self.assertRaises(content.ContentError):
                content.verify_go_events(encode(variant), 0, ["boundary"])
        with self.assertRaises(content.ContentError):
            content.verify_go_events(encode(events), 1, ["boundary"])
        with self.assertRaises(content.ContentError):
            content.verify_go_events(encode(events), 0, [])

    def test_declared_tests_cannot_be_removed(self):
        self.example["tests"] = []
        with self.assertRaises(content.ContentError):
            content.validate_catalog(self.catalog, ROOT)

    def test_path_must_stay_inside_repository(self):
        for path in ("../LICENSE", "/etc/passwd", "example//adoption/x", "example/./x"):
            with self.subTest(path=path), self.assertRaises(content.ContentError):
                content.relative_file(ROOT, path)


if __name__ == "__main__":
    unittest.main()

"""The native setup retry must stay bounded and must not hide failed setup."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeSetupRetry(unittest.TestCase):
    def setUp(self):
        workflow = (ROOT / '.github/workflows/native-parity.yml').read_text()
        parity = re.split(r'(?m)^  [a-zA-Z0-9_-]+:\n', workflow.split('\n  parity:\n', 1)[1], maxsplit=1)[0]
        self.steps = re.findall(r'^      - .*?(?=^      - |^  [a-zA-Z]|\Z)', parity, re.MULTILINE | re.DOTALL)
        self.setup = [step for step in self.steps if 'uses: ocaml/setup-ocaml@' in step]

    def test_bounded_attempts_keep_identical_toolchain_inputs(self):
        self.assertEqual(len(self.setup), 3)
        inputs = []
        for index, step in enumerate(self.setup, 1):
            self.assertIn(f'id: ocaml-setup-{index}\n', step)
            self.assertIn('uses: ocaml/setup-ocaml@ff66428f72b64472e749b22e0ad4dded4b2ddca6 # v3.9.1\n', step)
            inputs.append(step.split('        with:\n', 1)[1])
        self.assertEqual(inputs, [inputs[0]] * 3)
        self.assertIn('needs.plan.outputs.windows-ocaml', inputs[0])
        self.assertIn('needs.plan.outputs.ocaml', inputs[0])
        self.assertIn('windows-compiler: mingw', inputs[0])

    def test_verified_bootstrap_runs_before_setup_with_step_scoped_token(self):
        bootstrap = [step for step in self.steps if 'run: python scripts/bootstrap_opam.py' in step]
        self.assertEqual(len(bootstrap), 1)
        self.assertLess(self.steps.index(bootstrap[0]), self.steps.index(self.setup[0]))
        self.assertIn('GH_TOKEN: ${{ github.token }}', bootstrap[0])
        self.assertNotIn('continue-on-error:', bootstrap[0])
        self.assertNotIn('        if:', bootstrap[0])

    def test_retries_use_actual_failure_not_masked_conclusion(self):
        self.assertNotIn('        if:', self.setup[0])
        for index, step in enumerate(self.setup[1:], 1):
            self.assertIn(f"if: ${{{{ !cancelled() && steps.ocaml-setup-{index}.outcome == 'failure' }}}}", step)
        self.assertTrue(all('continue-on-error: true' in step for step in self.setup[:2]))
        self.assertNotIn('continue-on-error:', self.setup[2])

    def test_success_is_required_before_native_checks(self):
        guard = next(step for step in self.steps if 'name: Require successful OCaml setup' in step)
        condition = ' && '.join(['!cancelled()'] + [f"steps.ocaml-setup-{index}.outcome != 'success'" for index in range(1, 4)])
        self.assertIn('if: ${{ ' + condition + ' }}', guard)
        self.assertIn('raise SystemExit(', guard)
        self.assertNotIn('continue-on-error:', guard)
        checks = [step for step in self.steps if 'run: python scripts/native-parity.py ' in step]
        self.assertEqual(len(checks), 1)
        self.assertGreater(self.steps.index(checks[0]), self.steps.index(guard))
        self.assertNotIn('continue-on-error:', checks[0])
        self.assertNotIn('        if:', checks[0])

    def test_backoff_is_bounded_and_conditional(self):
        waits = [step for step in self.steps if 'time.sleep(' in step]
        self.assertEqual(len(waits), 2)
        for index, seconds in enumerate((15, 30), 1):
            self.assertIn(f'time.sleep({seconds})', waits[index - 1])
            self.assertIn(f"steps.ocaml-setup-{index}.outcome == 'failure'", waits[index - 1])
            self.assertIn('!cancelled()', waits[index - 1])


if __name__ == '__main__':
    unittest.main()

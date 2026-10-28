"""Local HTTP checks; no cluster required."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import unittest

import probe


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.reply()

    def do_POST(self):
        self.reply()

    def reply(self):
        self.server.paths.append(self.path)
        status, body = self.server.responses.get(
            self.path, (200, b'"created"' if self.path.startswith('/notes/') else b'true'))
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class ProbeTest(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.paths = []
        self.server.responses = {'/health': (200, b'{"release":1,"notes":0}')}
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}'

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_failures_are_samples_without_retries(self):
        for status, body in [(503, b'busy'), (200, b'invalid'),
                             (200, b'{"release":true,"notes":0}'), (302, b'')]:
            self.server.responses['/health'] = (status, body)
            result = probe.sample(self.url, 'health')
            self.assertFalse(result['ok'])
            self.assertEqual(result['status'], status)
            self.assertIn('error', result)
            self.assertGreaterEqual(result['latency_ms'], 0)
        self.assertEqual(len(self.server.paths), 4)
        self.server.responses['/jobs/bad'] = (200, b'false')
        self.assertFalse(probe.sample(self.url, 'jobs', 'bad')['ok'])

    def test_signal_report_and_exit_status(self):
        for sig, fail in [(signal.SIGTERM, False), (signal.SIGINT, True)]:
            if fail:
                self.server.responses['/health'] = (503, b'busy')
            with tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'report.json'
                child = subprocess.Popen(
                    [sys.executable, str(Path(probe.__file__)), '--url', self.url,
                     '--output', str(output), '--prefix', 'test', '--interval', '.01',
                     '--write-interval', '.01'], stdout=subprocess.PIPE, text=True)
                try:
                    self.assertIn('Probing', child.stdout.readline())
                    # Wait for actual accepted requests, rather than a startup sleep.
                    import time
                    deadline = time.monotonic() + 5
                    self.server.paths.clear()
                    while not any(p.startswith('/jobs/') for p in self.server.paths):
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(.01)
                    child.send_signal(sig)
                    child.communicate(timeout=5)
                    self.assertEqual(child.returncode, int(fail))
                    report = json.loads(output.read_text())
                    self.assertTrue(report['accepted_ids']['notes'])
                    self.assertTrue(report['accepted_ids']['jobs'])
                    self.assertEqual(bool(report['failures']), fail)
                    self.assertEqual(report['signals'], [sig.name])
                    self.assertEqual(report['observed_releases'], [] if fail else [1])
                    self.assertEqual(sum(v['attempts'] for v in report['summary'].values()),
                                     len(report['samples']))
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.communicate()


if __name__ == '__main__':
    unittest.main()

const path = require('node:path');
const dist = path.resolve(process.env.PLAYGROUND_DIST || path.join(__dirname, '../../playground/dist'));
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
module.exports = {
  testDir: __dirname, testMatch: '*.spec.cjs', workers: 1, timeout: 30000,
  outputDir: process.env.PLAYGROUND_TEST_OUTPUT || '/tmp/tesl-playground-browser-results',
  reporter: [['list']],
  use: { baseURL: process.env.PLAYGROUND_URL || 'http://127.0.0.1:18765',
    viewport: { width: 1280, height: 900 }, screenshot: 'only-on-failure', trace: 'retain-on-failure',
    launchOptions: { chromiumSandbox: false, args: ['--disable-dev-shm-usage'] } },
  webServer: process.env.PLAYGROUND_URL ? undefined : {
    command: `python3 -m http.server 18765 --bind 127.0.0.1 --directory ${quote(dist)}`,
    url: 'http://127.0.0.1:18765', reuseExistingServer: false
  }
};

import { defineConfig } from '@playwright/test';
import path from 'path';
import fs from 'fs';

// Launch the NIX-provided Chromium directly via executablePath (project-o's
// approach): the runner's pinned browser revision can differ from the nix
// bundle's, which makes the default launch fail with "Executable doesn't
// exist"; pointing at the full nix chrome sidesteps the revision coupling.
function nixChromium(): string | undefined {
  const base = process.env.PLAYWRIGHT_BROWSERS_PATH;
  if (!base) return undefined;
  try {
    const dir = fs
      .readdirSync(base)
      .find((d) => d.startsWith('chromium-') && !d.includes('headless'));
    if (!dir) return undefined;
    for (const sub of ['chrome-linux64', 'chrome-linux']) {
      const bin = path.join(base, dir, sub, 'chrome');
      if (fs.existsSync(bin)) return bin;
    }
  } catch {
    /* fall through */
  }
  return undefined;
}

export default defineConfig({
  testDir: '.',
  timeout: 30_000,
  reporter: [['list']],
  use: {
    // dex serves a loopback self-signed cert; accept it (the browser-side
    // equivalent of the backend's TESL_HTTP_TLS_INSECURE_DEV).
    ignoreHTTPSErrors: true,
    // Windowed run: `SSO_E2E_HEADED=1` opens a real browser (WSLg) in slow motion.
    headless: !process.env.SSO_E2E_HEADED,
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
    launchOptions: {
      executablePath: nixChromium(),
      // WSL / Nix sandbox: Chromium's own sandbox is unavailable.
      chromiumSandbox: false,
      slowMo: process.env.SSO_E2E_HEADED ? 700 : 0,
      args: ['--no-sandbox', '--disable-dev-shm-usage'],
    },
  },
});

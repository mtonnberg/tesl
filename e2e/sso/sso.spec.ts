import { test, expect } from '@playwright/test';

const APP = process.env.APP_ORIGIN || 'http://localhost:8080';

// Happy path: the whole SSO login through a real browser against a real dex —
// button -> dex login form -> callback -> code exchange + JWKS signature verify
// + userinfo -> __Host-session cookie -> back to "/" -> /me shows the subject.
test('log in with dex sets a session and /me shows the subject', async ({ page }) => {
  await page.goto(APP + '/');
  await expect(page.locator('#who')).toHaveText('not logged in');

  await page.click('#login'); // -> 303 to dex authorize
  await page.waitForLoadState('domcontentloaded');

  // dex's local-password login form (staticPasswords user).
  await page.fill('input[name="login"]', 'alice@example.com');
  await page.fill('input[name="password"]', 'password');
  await page.click('button[type="submit"], input[type="submit"], button:has-text("Login")');

  // dex (skipApprovalScreen) redirects to /auth/dex/callback, the runtime mints
  // the session and 303s to afterLogin ("/").
  await page.waitForURL(APP + '/**', { timeout: 15_000 });
  await expect(page.locator('#who')).toHaveText(/^logged in as: .+/);

  // The session cookie is the __Host- prefix, Secure + HttpOnly.
  const cookies = await page.context().cookies();
  const session = cookies.find((c) => c.name === '__Host-session');
  expect(session, '__Host-session cookie present').toBeTruthy();
  expect(session!.httpOnly).toBeTruthy();
  expect(session!.secure).toBeTruthy();

  // When watching in a window, linger on the logged-in page so you can see it.
  if (process.env.SSO_E2E_HEADED) await page.waitForTimeout(5000);
});

// Negative: the protected endpoint refuses an unauthenticated request.
test('the protected /me refuses without a session (401)', async ({ request }) => {
  const res = await request.get(APP + '/me');
  expect(res.status()).toBe(401);
});

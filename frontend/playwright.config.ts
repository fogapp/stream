import { defineConfig, devices } from "@playwright/test";

// The browser harness (hub's pattern). `npm run e2e` boots both halves of
// the app and drives the real SPA, so a change can be checked as rendered
// rather than only as typechecked — the things unit tests cannot see.
//
// Both servers are reused if already running, so an open `npm run dev` is
// picked up instead of fought with. Rails runs against the docker dev
// Postgres on 5437, in its own household (bin/rails e2e:seed) — see
// e2e/global-setup.ts. Ports are deliberately not the dev ones (3003/5177).
const API_PORT = Number(process.env.E2E_API_PORT ?? 3103);
const WEB_PORT = Number(process.env.E2E_WEB_PORT ?? 5277);
const DATABASE_PORT = process.env.DATABASE_PORT ?? "5437";

export default defineConfig({
  testDir: "./e2e",
  globalSetup: "./e2e/global-setup.ts",
  // Fixtures are a fixed, shared dataset: parallel workers mutating the same
  // household would race. The suite is small; keep it honest instead.
  workers: 1,
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [["github"], ["html", { open: "never" }]] : [["list"]],
  outputDir: "./e2e/.artifacts",
  use: {
    // The SPA proxies /api to Rails, so specs only ever need the web origin.
    baseURL: `http://127.0.0.1:${WEB_PORT}`,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    // The fixtures carry sine tones: Chromium and Chrome play them silently.
    // WebKit has no such switch; e2e/support/harness.ts quiets it instead.
    launchOptions: { args: ["--mute-audio"] },
  },
  projects: [
    // The UI suite. Playwright's own Chromium ships without H.264 and AAC, so
    // it can't prove playback; the playback suite runs in real browsers.
    { name: "chromium", use: { ...devices["Desktop Chrome"] }, testIgnore: /playback\.spec|offline\.spec|streaming\.spec|seams\.spec|changes\.spec|bench\.spec|pip\.spec/ },
    // PROPOSAL §11 Phase 2 exit: every file plays in Chrome and Safari.
    // Offline downloads and streaming through the transcoder (a seek, a
    // restart) need H.264 too, so they run in real Chrome.
    {
      name: "chrome",
      use: { ...devices["Desktop Chrome"], channel: "chrome" },
      testMatch: /playback\.spec|offline\.spec|streaming\.spec|seams\.spec|bench\.spec|pip\.spec/,
    },
    // What changes the library or the household itself — files moved, a
    // webhook's arrival, a library added, a member invited: after everything
    // that reads the seed as it was.
    { name: "changes", use: { ...devices["Desktop Chrome"] }, testMatch: /changes\.spec/, dependencies: ["chromium"] },
    { name: "webkit", use: { ...devices["Desktop Safari"], launchOptions: {} }, testMatch: /playback\.spec/ },
  ],
  webServer: [
    {
      // Passkeys need a domain for their relying party, never an IP: the
      // passkey spec browses as localhost (e2e/changes.spec.ts).
      command: `DATABASE_PORT=${DATABASE_PORT} E2E=1 STREAM_WEBAUTHN_RP_ID=localhost bin/rails server -p ${API_PORT}`,
      cwd: "..",
      url: `http://127.0.0.1:${API_PORT}/up`,
      reuseExistingServer: true,
      timeout: 120_000,
      stdout: "ignore",
      stderr: "pipe",
    },
    {
      // --host 127.0.0.1: Vite 8 binds only ::1 by default, and both the
      // health-check URL above and baseURL speak IPv4.
      command: `npm run dev -- --port ${WEB_PORT} --strictPort --host 127.0.0.1`,
      env: { API_TARGET: `http://127.0.0.1:${API_PORT}` },
      url: `http://127.0.0.1:${WEB_PORT}`,
      reuseExistingServer: true,
      timeout: 120_000,
      stdout: "ignore",
      stderr: "pipe",
    },
  ],
});

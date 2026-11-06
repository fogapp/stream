import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { test as base, expect, type Page } from "@playwright/test";

// Credentials and titles seeded by `bin/rails e2e:seed` (lib/tasks/e2e.rake)
// — keep the two in step.
export const HARNESS_USER = { email: "e2e@example.com", password: "passwordpassword" };

interface Session {
  token: string;
  user: unknown;
}

/** This run's session; global-setup.ts removes it before the first spec. */
export const SESSION_FILE = path.join(import.meta.dirname, "..", ".artifacts-session.json");

function readSession(): Session | null {
  try {
    return JSON.parse(readFileSync(SESSION_FILE, "utf8")) as Session;
  } catch {
    return null;
  }
}

// Signing in through the form on every spec would test the login page over
// and over. The token is what the app actually runs on (localStorage, see
// api/client.ts), so the harness mints one over the API and plants it before
// the first paint. Worker-scoped: minted once per run, because sessions#
// create is rate-limited (10 in 3 minutes).
export const test = base.extend<{ page: Page }, { session: Session }>({
  // Shared through a file for the whole run: a failed test restarts its
  // worker, and a fresh sign-in per worker would hit the rate limit after a
  // few failures and fail everything after them for the wrong reason.
  session: [
    async ({ playwright }, provide, workerInfo) => {
      const cached = readSession();
      if (cached) {
        await provide(cached);
        return;
      }
      const baseURL = workerInfo.project.use.baseURL;
      const ctx = await playwright.request.newContext({ baseURL });
      const response = await ctx.post("/api/v1/session", {
        data: { ...HARNESS_USER, device: "playwright" },
      });
      if (!response.ok()) {
        throw new Error(
          `Harness sign-in failed (${response.status()}). Is the fixture household seeded? ` +
            "Run DATABASE_PORT=5437 bin/rails e2e:seed",
        );
      }
      const session = (await response.json()) as Session;
      await ctx.dispose();
      writeFileSync(SESSION_FILE, JSON.stringify(session));
      await provide(session);
    },
    { scope: "worker" },
  ],

  page: async ({ page, session, browserName }, provide) => {
    if (browserName === "webkit") await page.addInitScript(silenceMedia);
    // Both halves of what AuthProvider boots from: the bearer token the API
    // client reads, and the cached user it decides "signed in" by.
    await page.addInitScript((s) => {
      window.localStorage.setItem("stream_api_token", s.token);
      window.localStorage.setItem("stream_user", JSON.stringify(s.user));
    }, session);
    await provide(page);
  },
});

// WebKit has no --mute-audio, and the fixtures' sine tones would come out of
// the speakers. Every element's real volume is held at 0, while the volume
// the app sets is the one it reads back — so the player's own volume and
// mute (which Grid's channel deck depends on) behave as they would.
function silenceMedia() {
  const descriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "volume")!;
  const wanted = new WeakMap<HTMLMediaElement, number>();
  const quiet = (element: HTMLMediaElement) => descriptor.set!.call(element, 0);
  Object.defineProperty(HTMLMediaElement.prototype, "volume", {
    configurable: true,
    get(this: HTMLMediaElement) {
      return wanted.get(this) ?? 1;
    },
    set(this: HTMLMediaElement, value: number) {
      wanted.set(this, value);
      quiet(this);
    },
  });
  // Media events don't bubble, but they do pass through a capturing listener.
  for (const event of ["loadstart", "play"]) {
    document.addEventListener(event, (e) => e.target instanceof HTMLMediaElement && quiet(e.target), true);
  }
}

export { expect };

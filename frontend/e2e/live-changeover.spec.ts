import { execFileSync } from "node:child_process";
import path from "node:path";
import { expect, test } from "./support/harness";

// The Grid's program changes (PROPOSAL §7.7), on a channel laid a few
// seconds from now (e2e:transitions): back to back, a file that runs out
// three seconds before its slot, then a ten-second gap. Each program is the
// harness's two-second file, so a whole evening's changes happen in a test.
const repoRoot = path.resolve(import.meta.dirname, "../..");
const env = { ...process.env, DATABASE_PORT: process.env.DATABASE_PORT ?? "5437", E2E: "1" };
const lay = (clear = false) =>
  execFileSync("bin/rails", [clear ? "e2e:transitions[clear]" : "e2e:transitions"], { cwd: repoRoot, env, encoding: "utf8" });

test.afterEach(() => {
  lay(true);
});

test("a channel moves from each program to the next by itself, through a gap's slate", async ({ page }) => {
  // Twenty-odd seconds of schedule, from a few seconds from now.
  test.setTimeout(90_000);
  const airings = JSON.parse(lay().trim().split("\n").at(-1)!) as { id: string; title: string }[];
  const transitions: { via: string; ready: boolean }[] = [];
  page.on("request", (request) => {
    if (request.method() !== "POST" || !request.url().endsWith("/events")) return;
    const body = JSON.parse(request.postData() ?? "{}") as { events?: { kind: string; detail: { via: string; ready: boolean } }[] };
    for (const event of body.events ?? []) if (event.kind === "transition") transitions.push(event.detail);
  });

  await page.goto("/live/7");
  // What was on screen, in order: each airing as it played, and the slate.
  await page.evaluate(() => {
    const seen: string[] = [];
    (window as unknown as { seen: string[] }).seen = seen;
    window.setInterval(() => {
      const playing = [...document.querySelectorAll<HTMLVideoElement>("video.visible")].find((video) => !video.paused && video.currentTime > 0.2);
      const now = document.querySelector("[data-testid=live-slate]") ? "slate" : (playing?.dataset.airing ?? null);
      if (now && seen.at(-1) !== now) seen.push(now);
    }, 50);
  });

  // Nothing's on yet: the slate, until the first program starts by itself —
  // joined at the second, since the first is all in its last ten seconds
  // (the server's TAIL) by the time it's asked for.
  await expect(page.getByTestId("live-slate")).toBeVisible();
  const [, second, early, afterEarly, afterGap] = airings.map((airing) => airing.id);
  await expect
    .poll(() => page.evaluate(() => (window as unknown as { seen: string[] }).seen), { timeout: 60_000 })
    .toEqual(["slate", second, early, afterEarly, "slate", afterGap]);

  // Every change was timed; the ones after the first were tuned ahead.
  await expect.poll(() => transitions.length).toBeGreaterThanOrEqual(4);
  expect(transitions.slice(1).filter((transition) => transition.ready).length).toBeGreaterThanOrEqual(3);
  expect(transitions.at(-1)?.via).toBe("gap");
});

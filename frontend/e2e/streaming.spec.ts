import type { APIRequestContext } from "@playwright/test";
import { startTranscoder, stopTranscoder } from "./support/transcoder";
import { expect, test } from "./support/harness";

// Streaming through the transcoder with room to move: the seed's Long Take
// is a three-minute MKV (the rest of the corpus is two seconds a file), which
// Chrome can only have repackaged. Real Chrome, for its H.264.

async function longTake(request: APIRequestContext, token: string) {
  const movies = (await (
    await request.get("/api/v1/movies?q=Long%20Take", { headers: { Authorization: `Bearer ${token}` } })
  ).json()) as { id: string; title: string }[];
  const movie = movies.find((candidate) => candidate.title === "Long Take");
  expect(movie, "the seed's Long Take").toBeTruthy();
  return movie!;
}

const position = (element: HTMLVideoElement) => element.currentTime;

test("a far seek restarts the stream there, and another device resumes from it", async ({ page, browser, session }) => {
  const movie = await longTake(page.request, session.token);
  const created = page.waitForResponse((response) => response.url().endsWith("/api/v1/playback_sessions") && response.request().method() === "POST");
  await page.goto(`/watch/movie/${movie.id}`);
  const body = await (await created).json();
  expect(body.method).toBe("remux");

  const video = page.locator("video");
  await expect.poll(() => video.evaluate(position), { timeout: 20_000 }).toBeGreaterThan(0.5);
  // Far past anything buffered: the transcoder has to start again at 2:30 —
  // and past two minutes, so it counts as started (WatchState::STARTED_AFTER).
  await video.evaluate((element: HTMLVideoElement) => {
    element.currentTime = 150;
  });
  await expect.poll(() => video.evaluate(position), { timeout: 20_000 }).toBeGreaterThan(151);
  await expect(page.getByText(/couldn't (play|be played)/i)).toHaveCount(0);
  // A far seek restarts ffmpeg; the proposal's target is 800 ms for a remux (§6.4), doubled for CI.
  const seek = Number(await video.getAttribute("data-seek-ms"));
  test.info().annotations.push({ type: "far seek", description: `${seek} ms` });
  console.log(`far seek: ${seek} ms, startup: ${await video.getAttribute("data-startup-ms")} ms`);
  expect(seek, "seek ms").toBeGreaterThan(0);
  expect(seek, `far seek landed in ${seek} ms`).toBeLessThan(1_600);

  // Pausing reports where it got to: wait for that report, not an earlier one.
  const progress = page.waitForRequest(
    (request) => request.url().includes("/progress") && Number(JSON.parse(request.postData() ?? "{}").position) >= 150,
  );
  await page.keyboard.press("k");
  await progress;

  // Another browser, signed in as the same person, on a device of its own.
  const other = await browser.newContext();
  await other.addInitScript((s) => {
    window.localStorage.setItem("stream_api_token", s.token);
    window.localStorage.setItem("stream_user", JSON.stringify(s.user));
    window.localStorage.setItem("stream_device", "second-device");
  }, session);
  const tv = await other.newPage();
  await tv.goto("/");
  const continuing = tv.getByRole("region").filter({ has: tv.getByRole("heading", { name: "Continue watching" }) });
  await expect(continuing.getByRole("link", { name: /Long Take/ })).toBeVisible();
  await tv.goto(`/movie/${movie.id}`);
  await tv.getByRole("button", { name: /Resume from 2:3\d/ }).click();
  await expect.poll(() => tv.locator("video").evaluate(position), { timeout: 20_000 }).toBeGreaterThan(150);
  await other.close();
});

// What a deploy does (CLAUDE.md, Deployment): the transcoder goes away and a
// new one takes over. Session state is in Postgres and segments on the shared
// cache, so the same session keeps going — a seek after the swap is served
// by the new transcoder.
test("a playing session survives the transcoder being replaced", async ({ page, session }) => {
  const movie = await longTake(page.request, session.token);
  let sessions = 0;
  page.on("request", (request) => {
    if (request.url().endsWith("/api/v1/playback_sessions") && request.method() === "POST") sessions += 1;
  });
  await page.goto(`/watch/movie/${movie.id}`);
  const video = page.locator("video");
  await expect.poll(() => video.evaluate(position), { timeout: 20_000 }).toBeGreaterThan(0.5);

  stopTranscoder();
  startTranscoder();

  await video.evaluate((element: HTMLVideoElement) => {
    element.currentTime = 165;
  });
  await expect.poll(() => video.evaluate(position), { timeout: 30_000 }).toBeGreaterThan(166);
  expect(sessions).toBe(1);
  await expect(page.getByText(/couldn't (play|be played)/i)).toHaveCount(0);
});

// docs/PERF_PROPOSAL.md › P14: dragging the timeline previews where it
// would land and seeks once, on release — a seek per pointer move restarted
// the transcoder at each one.
test("dragging the timeline seeks once, where it's let go", async ({ page, session }) => {
  const movie = await longTake(page.request, session.token);
  await page.goto(`/watch/movie/${movie.id}`);
  const video = page.locator("video");
  await expect.poll(() => video.evaluate(position), { timeout: 20_000 }).toBeGreaterThan(0.5);
  await video.evaluate((element: HTMLVideoElement) => {
    (window as unknown as { seeks: number }).seeks = 0;
    element.addEventListener("seeking", () => ((window as unknown as { seeks: number }).seeks += 1));
  });

  await page.mouse.move(400, 300);
  const bar = page.getByRole("slider", { name: "Seek" });
  const box = (await bar.boundingBox())!;
  const y = box.y + box.height / 2;
  await page.mouse.move(box.x + box.width * 0.1, y);
  await page.mouse.down();
  for (let step = 2; step <= 8; step += 1) await page.mouse.move(box.x + box.width * (step / 10), y, { steps: 3 });
  expect(await page.evaluate(() => (window as unknown as { seeks: number }).seeks)).toBe(0);
  await page.mouse.up();

  await expect.poll(() => page.evaluate(() => (window as unknown as { seeks: number }).seeks)).toBe(1);
  await expect.poll(() => video.evaluate(position), { timeout: 20_000 }).toBeGreaterThan(180 * 0.79);
});

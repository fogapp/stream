import type { APIRequestContext } from "@playwright/test";
import { read, type Reading } from "./support/film";
import { expect, test } from "./support/harness";

// Seams: where what one ffmpeg run made meets what another did, and where
// what a seek left buffered meets what's buffered up to it. The seed's Long
// Take is made the way a real film is (lib/tasks/e2e.rake) and says in its
// picture what second it is, so the frame on screen can be held against the
// player's clock. In real Chrome (hls.js) and in WebKit (its own HLS).

async function longTake(request: APIRequestContext, token: string) {
  const movies = (await (
    await request.get("/api/v1/movies?q=Long%20Take", { headers: { Authorization: `Bearer ${token}` } })
  ).json()) as { id: string; title: string }[];
  const movie = movies.find((candidate) => candidate.title === "Long Take");
  expect(movie, "the seed's Long Take").toBeTruthy();
  return movie!;
}

const position = (element: HTMLVideoElement) => element.currentTime;

// Where the seed puts the film's keyframes (lib/tasks/e2e.rake — keep the
// two in step): the gaps between them, over and over.
const GAPS = [5.0, 4.3, 6.7, 10.4, 2.5, 2.1, 4.8, 4.5, 2.1, 10.4, 2.2, 2.4, 3.2, 10.4, 2.0, 3.5, 5.3, 2.6];
const KEYFRAMES = Array.from({ length: 36 }, (_, index) => index).reduce<number[]>(
  (times, index) => [...times, times[index]! + GAPS[index % GAPS.length]!],
  [0],
);

// The film is left as it was found — unwatched, from the top — for the
// specs that play it next.
test.afterEach(async ({ page, session }) => {
  const movie = await longTake(page.request, session.token);
  // Away from the player first: its last report mustn't land after this.
  const stopped = page.waitForRequest((request) => request.url().includes("/progress")).catch(() => null);
  await page.goto("/");
  await stopped;
  const reset = await page.request.post("/api/v1/watch_states", {
    headers: { Authorization: `Bearer ${session.token}` },
    data: { playable_type: "movie", playable_id: movie.id, watched: false },
  });
  expect(reset.ok()).toBe(true);
});

// What a night of Grid did (2026-10-01): back along the timeline a few
// times, then playing on through the pieces each seek had left buffered.
// Every restarted run began a keyframe early, so the picture was a GOP away
// from the clock; and Chrome threw away the first GOP of each piece as the
// one before it arrived, so the sound carried on over a frozen picture.
// The film's picture says what second it is: it has to stay with the clock.
test("seeking back and playing on through what was buffered keeps the picture with the clock", async ({ page, session }) => {
  test.setTimeout(150_000);
  const movie = await longTake(page.request, session.token);
  await page.goto(`/watch/movie/${movie.id}`);
  const video = page.locator("video");
  await expect.poll(() => video.evaluate(position), { timeout: 20_000 }).toBeGreaterThan(0.5);
  // Come back to it most of the way through, so what the player buffers
  // first isn't the part of the film the stops below are in.
  await video.evaluate((element: HTMLVideoElement) => {
    element.currentTime = 150;
  });
  await expect.poll(() => video.evaluate(position), { timeout: 20_000 }).toBeGreaterThan(151);
  const reported = page.waitForRequest(
    (request) => request.url().includes("/progress") && Number(JSON.parse(request.postData() ?? "{}").position) >= 150,
  );
  await page.keyboard.press("k");
  await reported;
  await page.reload();
  await expect.poll(() => video.evaluate(position), { timeout: 20_000 }).toBeGreaterThan(151);
  const together = (reading: Reading) => reading.picture !== null && Math.abs(reading.picture - Math.floor(reading.time)) <= 1;

  // Back along the film a GOP at a time, a moment in each: every stop leaves
  // what it buffered ahead of the next, which then fetches the GOP in front
  // of it. Which keyframes Chrome drops a GOP at depends on how the
  // encoder ordered that GOP's last frames — about half of them, and not
  // the same ones from one ffmpeg to the next — so the stops take in
  // seventeen in a row.
  const stops = KEYFRAMES.slice(11, 28).reverse().map((keyframe) => keyframe + 0.6);
  for (const target of stops) {
    await video.evaluate((element: HTMLVideoElement, to) => {
      element.currentTime = to;
    }, target);
    await expect.poll(() => video.evaluate(position), { timeout: 20_000 }).toBeGreaterThan(target + 0.8);
    const landed = await read(video);
    expect(together(landed), `after seeking to ${target}: frame ${landed.picture} at ${landed.time.toFixed(2)}`).toBe(true);
  }

  // And on through all of them, twice as fast as the film.
  await video.evaluate((element: HTMLVideoElement) => {
    element.playbackRate = 2;
  });
  const readings: Reading[] = [];
  const until = Date.now() + 90_000;
  while (Date.now() < until) {
    const reading = await read(video);
    readings.push(reading);
    if (reading.time > 140) break;
    await page.waitForTimeout(200);
  }
  expect(readings.at(-1)!.time, "played on past every piece").toBeGreaterThan(140);
  const apart = readings.filter((reading) => !reading.seeking && !together(reading));
  expect(apart.map((reading) => `frame ${reading.picture} at ${reading.time.toFixed(2)}`), "picture and clock apart").toEqual([]);
  await expect(page.getByText(/couldn't (play|be played)/i)).toHaveCount(0);
});

import { execFileSync } from "node:child_process";
import type { APIRequestContext, Page } from "@playwright/test";
import { expect, test } from "./support/harness";

// A play that fails carries on a rung down the ladder, from where it got to,
// without a banner. Failures are forced
// at the network: a stream the transcoder gave up on, and a file the
// browser can't open. Real Chrome, whose requests Playwright can answer
// (Safari's native HLS fetches outside the page).

async function movie(request: APIRequestContext, token: string, title: string) {
  const headers = { Authorization: `Bearer ${token}` };
  const found = (await (await request.get(`/api/v1/movies?q=${encodeURIComponent(title)}&per=100`, { headers })).json()) as { id: string; title: string }[];
  const match = found.find((candidate) => candidate.title === title);
  expect(match, title).toBeTruthy();
  return match!;
}

function sessionCreated(page: Page) {
  return page.waitForResponse((response) => response.url().endsWith("/api/v1/playback_sessions") && response.request().method() === "POST");
}

function fellBack(page: Page) {
  return page.waitForResponse((response) => /\/api\/v1\/playback_sessions\/[^/]+\/fallback$/.test(response.url()));
}

const position = (element: HTMLVideoElement) => element.currentTime;

// What these forced failures teach is
// forgotten after: the playback suite expects each file's cheapest way.
test.afterAll(() => {
  execFileSync("bin/rails", ["runner", 'Playability.unscoped.joins(:household).where(households: { name: "E2E Harness" }).delete_all'], {
    cwd: "..",
    env: { ...process.env, DATABASE_PORT: process.env.DATABASE_PORT ?? "5437" },
  });
});

test.beforeEach(({ browserName }, info) => {
  test.skip(info.project.name !== "chrome" || browserName !== "chromium", "Chrome's own requests are the ones a test can answer");
});

test("a stream the transcoder gave up on carries on a rung down, from where it was", async ({ page, session }) => {
  test.setTimeout(120_000);
  const longTake = await movie(page.request, session.token, "Long Take");
  // Once it's playing, the first segment asked for is answered the way a
  // transcoder that gave up answers (Playback::Segments::Failed).
  let armed = false;
  let refused = false;
  await page.route(/\/media\/s\/[^/]+\/hls\/seg-\d+\.m4s$/, async (route) => {
    if (armed && !refused) {
      refused = true;
      await route.fulfill({ status: 424, contentType: "text/plain", body: "ffmpeg exited 1: forced by the test" });
      return;
    }
    await route.continue();
  });

  const created = sessionCreated(page);
  await page.goto(`/watch/movie/${longTake.id}`);
  const first = await (await created).json();
  expect(first.method).toBe("remux");
  const video = page.locator("video");
  await expect.poll(() => video.evaluate(position), { timeout: 30_000 }).toBeGreaterThan(3);

  // Far ahead, where nothing is buffered: the next segment fails.
  armed = true;
  const fallback = fellBack(page);
  await video.evaluate((element: HTMLVideoElement) => {
    element.currentTime = 100;
  });
  const answer = await fallback;
  expect(answer.status()).toBe(201);
  expect(JSON.parse(answer.request().postData() ?? "{}")).toMatchObject({ failure_class: "server" });
  const carried = await answer.json();
  expect(carried.method).toBe("audio_transcode");
  expect(carried.fallback).toEqual({ from_method: "remux", failure_class: "server", upgradable: false });
  expect(carried.resume_at).toBeGreaterThanOrEqual(99);

  await expect(page.getByRole("status").filter({ hasText: "Switched to a steadier stream" })).toBeVisible();
  await expect.poll(() => video.evaluate(position), { timeout: 30_000 }).toBeGreaterThan(carried.resume_at + 3);
  await expect(page.getByText(/couldn't (play|be played)/i)).toHaveCount(0);
});

test("a file the browser can't open plays repackaged instead", async ({ page, session }) => {
  test.setTimeout(120_000);
  const mp4 = await movie(page.request, session.token, "Case H264 AAC MP4");
  // Not a film at all, under the original's address.
  await page.route(/\/media\/s\/[^/]+\/original\.mp4$/, (route) =>
    route.fulfill({ status: 200, contentType: "video/mp4", body: Buffer.from("this is not a video ".repeat(64)) }),
  );

  const created = sessionCreated(page);
  const fallback = fellBack(page);
  await page.goto(`/watch/movie/${mp4.id}`);
  expect((await (await created).json()).method).toBe("direct");

  const answer = await fallback;
  expect(answer.status()).toBe(201);
  expect(JSON.parse(answer.request().postData() ?? "{}").failure_class).toMatch(/unsupported|decode/);
  const carried = await answer.json();
  expect(["remux", "video_transcode"]).toContain(carried.method);
  const video = page.locator("video");
  await expect.poll(() => video.evaluate(position), { timeout: 30_000 }).toBeGreaterThan(0.5);
  await expect(page.getByText(/couldn't (play|be played)/i)).toHaveCount(0);
});

test("a play with no rung left says why at the top right and goes back to the title's page", async ({ page, session }) => {
  test.setTimeout(120_000);
  const mp4 = await movie(page.request, session.token, "Case H264 AAC MP4");
  // Whichever way it's played (the test before taught it to repackage): not a film at all.
  await page.route(/\/media\/s\/[^/]+\/(original\.mp4|hls\/[^/]+\.(mp4|m4s))$/, (route) =>
    route.fulfill({ status: 200, contentType: "video/mp4", body: Buffer.from("this is not a video ".repeat(64)) }),
  );
  // Nowhere lower to go, the way the server says it.
  await page.route(/\/api\/v1\/playback_sessions\/[^/]+\/fallback$/, (route) =>
    route.fulfill({ status: 409, contentType: "application/json", body: JSON.stringify({ errors: ["This couldn't be played on Chrome. Tried direct play: the browser couldn't open it."] }) }),
  );

  await page.goto(`/movie/${mp4.id}`);
  await page.goto(`/watch/movie/${mp4.id}`);

  const alert = page.getByRole("alert").filter({ hasText: "Couldn't play Case H264 AAC MP4" });
  await expect(alert).toBeVisible({ timeout: 45_000 });
  await expect(alert).toContainText("Tried direct play");
  await expect(page).toHaveURL(new RegExp(`/movie/${mp4.id}$`));
  await expect(page.locator("video")).toHaveCount(0);
  // Top right, and it stays until it's dismissed.
  const box = await alert.boundingBox();
  const viewport = page.viewportSize()!;
  expect(box!.y).toBeLessThan(viewport.height / 2);
  expect(box!.x + box!.width).toBeGreaterThan(viewport.width / 2);
  await page.waitForTimeout(7_000);
  await expect(alert).toBeVisible();
  await alert.getByRole("button", { name: "Dismiss" }).click();
  await expect(alert).toHaveCount(0);
});

test("a play the server won't start says why and goes back where it was pressed", async ({ page, session }) => {
  const mp4 = await movie(page.request, session.token, "Case H264 AAC MP4");
  await page.route(/\/api\/v1\/playback_sessions$/, (route) =>
    route.request().method() === "POST"
      ? route.fulfill({ status: 409, contentType: "application/json", body: JSON.stringify({ errors: ["There's no readable file for this yet"] }) })
      : route.continue(),
  );

  await page.goto(`/movie/${mp4.id}`);
  await page.goto(`/watch/movie/${mp4.id}`);

  await expect(page.getByRole("alert").filter({ hasText: "There's no readable file for this yet" })).toBeVisible();
  await expect(page).toHaveURL(new RegExp(`/movie/${mp4.id}$`));
});

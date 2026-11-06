import { execFileSync } from "node:child_process";
import path from "node:path";
import type { APIRequestContext, Locator, Page } from "@playwright/test";
import { expect, test } from "./support/harness";
import { LiveSource } from "./support/liveSource";

// PROPOSAL §7.3: a second picture in an inset over the one playing — a
// camera over a film, a Grid channel over a film — whose sound can be
// either's or both, and which swaps places with the main picture without
// either starting over. Real Chrome: the pictures are H.264. The seed's
// files are seconds long, so the film is its Long Take — put on channel 5
// too, on now and a minute and a half in, and taken off again after.

const REPO = path.resolve(import.meta.dirname, "../..");
const rails = (script: string) =>
  execFileSync("bin/rails", ["runner", script], {
    cwd: REPO,
    env: { ...process.env, DATABASE_PORT: process.env.DATABASE_PORT ?? "5437", E2E: "1" },
    encoding: "utf8",
  }).trim();
const CHANNEL = `
  household = Household.find_by!(name: "E2E Harness")
  station = Station.unscoped.find_by!(household_id: household.id, number: "5")
  airing = Airing.unscoped.where(station_id: station.id).where("starts_at <= ? AND ends_at > ?", Time.current, Time.current).first!
`;
let before = "";

const source = new LiveSource();
let api: APIRequestContext;
let libraryId = "";
let streamId = "";
let filmId = "";

test.beforeAll(async ({ playwright, session }, testInfo) => {
  before = rails(`${CHANNEL}
    film = Movie.unscoped.find_by!(household_id: household.id, title: "Long Take")
    file = MediaFile.unscoped.find_by!(household_id: household.id, id: film.media_files.unscope(where: :household_id).pick(:id))
    puts({ id: airing.id, playable_type: airing.playable_type, playable_id: airing.playable_id, media_file_id: airing.media_file_id,
           starts_at: airing.starts_at.iso8601(3), ends_at: airing.ends_at.iso8601(3) }.to_json)
    started = 90.seconds.ago
    airing.update_columns(playable_type: "Movie", playable_id: film.id, media_file_id: file.id, starts_at: started, ends_at: started + file.duration_seconds)
  `)
    .split("\n")
    .at(-1)!;
  await source.open();
  api = await playwright.request.newContext({
    baseURL: testInfo.project.use.baseURL,
    extraHTTPHeaders: { Authorization: `Bearer ${session.token}` },
  });
  const library = await api.post("/api/v1/libraries", { data: { library: { name: "PiP cameras", kind: "live" } } });
  expect(library.ok(), await library.text()).toBe(true);
  libraryId = ((await library.json()) as { id: string }).id;
  const stream = await api.post("/api/v1/live_streams", {
    data: { live_stream: { name: "Porch camera", library_id: libraryId, kind: "web", url: source.url } },
  });
  expect(stream.ok(), await stream.text()).toBe(true);
  streamId = ((await stream.json()) as { id: string }).id;

  const libraries = (await (await api.get("/api/v1/libraries")).json()) as { id: string; name: string }[];
  const corpus = libraries.find((candidate) => candidate.name === "Corpus");
  const movies = (await (await api.get(`/api/v1/movies?library_id=${corpus!.id}&per=100`)).json()) as { id: string; title: string }[];
  filmId = movies.find((movie) => movie.title === "Long Take")!.id;
});

test.afterAll(async () => {
  if (before) {
    rails(`was = JSON.parse(${JSON.stringify(before)})
      Airing.unscoped.where(id: was.fetch("id")).update_all(was.except("id"))`);
  }
  if (libraryId) await api.delete(`/api/v1/libraries/${libraryId}`);
  await api.dispose();
  await source.close();
});

/** The picture is moving: the element's clock runs on while it plays. */
async function playing(video: Locator) {
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.readyState >= 2 && !element.paused), { timeout: 30_000 }).toBe(true);
  const at = await video.evaluate((element: HTMLVideoElement) => element.currentTime);
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 15_000 }).toBeGreaterThan(at + 0.5);
}

const muted = (video: Locator) => video.evaluate((element: HTMLVideoElement) => element.muted);

/** The film, full screen, its element marked so a swap can be seen not to replace it. */
async function startFilm(page: Page): Promise<Locator> {
  await page.goto(`/watch/movie/${filmId}`);
  const film = page.locator("video").first();
  await playing(film);
  await film.evaluate((element: HTMLVideoElement) => {
    element.dataset.film = "1";
  });
  return page.locator("video[data-film]");
}

/** Counts the sessions asked for from here on: a swap mustn't ask for any. */
function countTunes(page: Page) {
  const tunes: string[] = [];
  page.on("request", (request) => {
    if (request.method() === "POST" && request.url().endsWith("/api/v1/playback_sessions")) tunes.push(request.postData() ?? "");
  });
  return tunes;
}

test("a camera plays in the inset over a film, with either's sound, and swaps places without starting over", async ({ page }) => {
  test.setTimeout(150_000);
  const film = await startFilm(page);

  await page.mouse.move(400, 300);
  await page.getByRole("button", { name: "Picture in picture" }).click();
  await page.getByRole("menuitem", { name: "Porch camera" }).click();
  const inset = page.getByTestId("pip");
  await expect(inset).toBeVisible();
  const camera = inset.locator("video");
  await playing(camera);
  // The inset starts silent; the film carries on with its sound.
  expect(await muted(camera)).toBe(true);
  expect(await muted(film)).toBe(false);

  await inset.hover();
  await inset.getByRole("radio", { name: "Inset" }).click();
  expect(await muted(camera)).toBe(false);
  expect(await muted(film)).toBe(true);
  await inset.getByRole("radio", { name: "Both" }).click();
  expect(await muted(camera)).toBe(false);
  expect(await muted(film)).toBe(false);
  await inset.getByRole("radio", { name: "Inset" }).click();

  // Swap: the camera's page, its session handed over; the film in the
  // inset, the same element still playing — and the sound stays with the
  // inset, so now it's the film's.
  const tunes = countTunes(page);
  await page.keyboard.press("x");
  await expect(page).toHaveURL(new RegExp(`/stream/${streamId}$`));
  await expect(inset.locator("video[data-film]")).toHaveCount(1);
  await playing(film);
  const main = page.locator("video:not([data-film])");
  await playing(main);
  expect(await muted(main)).toBe(true);
  expect(await muted(film)).toBe(false);

  // And back: the film's own page again, and the camera in the inset.
  await page.keyboard.press("x");
  await expect(page).toHaveURL(new RegExp(`/watch/movie/${filmId}$`));
  await expect(inset.locator("video[data-film]")).toHaveCount(0);
  await playing(film);
  await playing(inset.locator("video"));
  expect(await muted(inset.locator("video"))).toBe(false);
  expect(await muted(film)).toBe(true);
  expect(tunes, "a swap hands sessions over rather than asking for new ones").toEqual([]);

  // Closed, the inset is gone and the film plays on.
  await inset.hover();
  await inset.getByRole("button", { name: "Close picture in picture" }).click();
  await expect(inset).toHaveCount(0);
  await playing(film);
});

test("a Grid channel plays in the inset over a film, and swaps onto its own page and back", async ({ page }) => {
  test.setTimeout(150_000);
  const film = await startFilm(page);

  await page.mouse.move(400, 300);
  await page.getByRole("button", { name: "Picture in picture" }).click();
  await page.getByRole("menuitem", { name: "5 Movies · Long Take" }).click();
  const inset = page.getByTestId("pip");
  await playing(inset.locator("video"));

  const tunes = countTunes(page);
  await inset.hover();
  await inset.getByRole("button", { name: "Swap pictures (x)" }).click();
  await expect(page).toHaveURL(/\/live\/5$/);
  await expect(page.getByTestId("channel-banner")).toBeVisible({ timeout: 15_000 });
  await playing(page.locator("video.visible"));
  await expect(inset.locator("video[data-film]")).toHaveCount(1);
  await playing(film);
  // Channel 5 came over from the inset; only its neighbours are tuned (ahead, on standby).
  expect(tunes.filter((body) => !body.includes('"standby":true'))).toEqual([]);

  await page.keyboard.press("x");
  await expect(page).toHaveURL(new RegExp(`/watch/movie/${filmId}$`));
  await playing(film);
  await playing(inset.locator("video"));
  // And back into the inset: handed over by the channel's page, not tuned again.
  expect(tunes.filter((body) => !body.includes('"standby":true'))).toEqual([]);
});


/** Drags the inset by a point on its picture, clear of its buttons. */
async function dragInset(page: Page, inset: Locator) {
  const box = (await inset.boundingBox())!;
  const at = { x: box.x + box.width * 0.15, y: box.y + box.height * 0.55 };
  await page.mouse.move(at.x, at.y);
  await page.mouse.down();
  await page.mouse.move(at.x - 120, at.y + 80, { steps: 8 });
  await page.mouse.up();
  const moved = (await inset.boundingBox())!;
  expect(Math.round(moved.x - box.x)).toBe(-120);
  expect(Math.round(moved.y - box.y)).toBe(80);
}

test("a title in the inset has the corner's controls, drags by its picture, and goes when the main picture takes the corner", async ({ page }) => {
  test.setTimeout(150_000);
  const film = await startFilm(page);
  await page.mouse.move(400, 300);
  await page.getByRole("button", { name: "Picture in picture" }).click();
  await page.getByRole("menuitem", { name: "Porch camera" }).click();
  const inset = page.getByTestId("pip");
  await playing(inset.locator("video"));
  await dragInset(page, inset);

  // The film into the inset: rewind, play and pause, skip forward.
  await page.keyboard.press("x");
  await expect(inset.locator("video[data-film]")).toHaveCount(1);
  await playing(film);
  await dragInset(page, inset);
  await inset.hover();
  const at = await film.evaluate((element: HTMLVideoElement) => element.currentTime);
  await inset.getByRole("button", { name: "Skip forward 10 seconds" }).click();
  await expect.poll(() => film.evaluate((element: HTMLVideoElement) => element.currentTime)).toBeGreaterThan(at + 8);
  const ahead = await film.evaluate((element: HTMLVideoElement) => element.currentTime);
  await inset.getByRole("button", { name: "Rewind 10 seconds" }).click();
  await expect.poll(() => film.evaluate((element: HTMLVideoElement) => element.currentTime)).toBeLessThan(ahead - 5);
  await inset.getByRole("button", { name: "Pause", exact: true }).click();
  await expect.poll(() => film.evaluate((element: HTMLVideoElement) => element.paused)).toBe(true);
  await inset.getByRole("button", { name: "Play", exact: true }).click();
  await playing(film);

  // Back to the film's page, then away from it: the film takes the corner and the camera stops.
  await page.keyboard.press("x");
  await expect(page).toHaveURL(new RegExp(`/watch/movie/${filmId}$`));
  await playing(inset.locator("video"));
  await page.mouse.move(400, 300);
  await page.getByRole("button", { name: "Back", exact: true }).click();
  await expect(page.getByRole("region", { name: /^Now playing/ })).toBeVisible();
  await expect(inset).toHaveCount(0);
  await playing(film);

  // Picture in picture from a camera's card while the film is in the corner:
  // the film comes back over the page with the camera over it.
  await page.getByRole("link", { name: "PiP cameras" }).first().click();
  await page.getByRole("button", { name: "Picture in picture: Porch camera" }).click();
  await expect(page.getByRole("region", { name: /^Now playing/ })).toHaveCount(0);
  await playing(inset.locator("video"));
  await playing(film);
  // And back to the corner: the camera goes again.
  await page.mouse.move(400, 300);
  await page.getByRole("button", { name: "Back", exact: true }).click();
  await expect(page.getByRole("region", { name: /^Now playing/ })).toBeVisible();
  await expect(inset).toHaveCount(0);
});

/** The inset lies wholly inside the main picture. */
async function within(inset: Locator, main: Locator) {
  const outer = (await main.boundingBox())!;
  const inner = (await inset.boundingBox())!;
  expect(inner.x).toBeGreaterThanOrEqual(outer.x);
  expect(inner.y).toBeGreaterThanOrEqual(outer.y);
  expect(inner.x + inner.width).toBeLessThanOrEqual(outer.x + outer.width + 0.5);
  expect(inner.y + inner.height).toBeLessThanOrEqual(outer.y + outer.height + 0.5);
}

test("the inset stays inside a video playing in its page, and clear of the Related panel", async ({ page }) => {
  test.setTimeout(150_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "YouTube" }).click();
  await page.getByRole("complementary", { name: "Channels" }).getByRole("link", { name: /Technology Connections/ }).click();
  await page.getByRole("link", { name: "Channel page" }).click();
  await page.getByRole("link", { name: /The dishwasher, revisited/ }).first().click();
  const player = page.getByRole("region", { name: /Now playing: The dishwasher, revisited/ });
  const main = player.locator("video");
  // Seconds long: round again, so it's still playing when the controls are wanted.
  await main.evaluate((element: HTMLVideoElement) => {
    element.loop = true;
  });
  await playing(main);
  const videoId = new URL(page.url()).pathname.split("/").at(-1)!;

  await player.hover();
  await player.getByRole("button", { name: "Picture in picture" }).click();
  await page.getByRole("menuitem", { name: "Porch camera" }).click();
  const inset = page.getByTestId("pip");
  await playing(inset.locator("video"));
  await within(inset, main);
  // It scrolls with the page, the picture under it.
  await page.mouse.wheel(0, 150);
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(0);
  await within(inset, main);

  // Full screen with the Related panel open: inside the picture beside it.
  await page.goto(`/watch/video/${videoId}`);
  const film = page.locator("video").first();
  await film.evaluate((element: HTMLVideoElement) => {
    element.loop = true;
  });
  await playing(film);
  await page.mouse.move(400, 300);
  const related = page.getByRole("button", { name: "Related" });
  if ((await related.getAttribute("aria-pressed")) !== "true") await related.click();
  await page.getByRole("button", { name: "Picture in picture" }).click();
  await page.getByRole("menuitem", { name: "Porch camera" }).click();
  await playing(inset.locator("video"));
  await within(inset, film);
});

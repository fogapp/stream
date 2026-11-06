import { readFileSync } from "node:fs";
import path from "node:path";
import { expect, test } from "./support/harness";

// Subtitles, from the file beside the film to words on the picture: found by
// the scanner (Plex naming), converted to WebVTT in storage, offered by the
// session, and drawn by the browser.
test("a sidecar subtitle is offered, and its lines show on the picture", async ({ page, session }) => {
  const movies = (await (
    await page.request.get("/api/v1/movies?q=Case%20VP9", { headers: { Authorization: `Bearer ${session.token}` } })
  ).json()) as { id: string; title: string }[];
  const movie = movies.find((candidate) => candidate.title === "Case VP9 Opus")!;

  await page.goto(`/watch/movie/${movie.id}`);
  const video = page.locator("video");
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.readyState), { timeout: 10_000 }).toBeGreaterThan(0);
  // Paused, the controls stay up.
  await video.evaluate((element: HTMLVideoElement) => element.pause());
  await page.mouse.move(400, 300);
  const menu = page.getByRole("button", { name: "Subtitles" });
  await menu.click();
  await page.getByRole("radiogroup", { name: "Subtitles" }).getByRole("radio", { name: /English/ }).check();

  // Once the track has loaded, the seed's line is one of its cues.
  const cues = () =>
    video.evaluate((element: HTMLVideoElement) =>
      Array.from(element.textTracks)
        .filter((track) => track.mode === "showing")
        .flatMap((track) => Array.from(track.cues ?? []).map((cue) => (cue as VTTCue).text)),
    );
  await expect.poll(cues, { timeout: 10_000 }).toContain("A line from the sidecar.");

  await page.mouse.move(420, 320);
  if (!(await page.getByRole("radiogroup", { name: "Subtitles" }).isVisible())) await menu.click();
  await page.getByRole("radiogroup", { name: "Subtitles" }).getByRole("radio", { name: "Off" }).check();
  await expect.poll(cues).toEqual([]);
});

// The Apple TV app decodes fixtures captured from this harness
// (clients/appletv/StreamTVTests/Fixtures). They're refreshed by hand, so a
// serializer that drops or renames a field the app reads would pass its
// tests while the TV broke. Every field a fixture has must still be served.
test("every field the Apple TV app reads is still served", async ({ page, session }) => {
  const headers = { Authorization: `Bearer ${session.token}` };
  const get = async (url: string) => (await (await page.request.get(`/api/v1${url}`, { headers })).json()) as unknown;
  const fixtures = path.resolve(import.meta.dirname, "../../clients/appletv/StreamTVTests/Fixtures");
  const fixture = (name: string) => JSON.parse(readFileSync(path.join(fixtures, `${name}.json`), "utf8")) as unknown;

  const movies = (await get("/movies?q=Heat")) as { id: string; title: string }[];
  const shows = (await get("/shows?q=Severance")) as { id: string }[];
  const live = {
    home: await get("/home"),
    movie: await get(`/movies/${movies.find((movie) => movie.title === "Heat")!.id}`),
    show: await get(`/shows/${shows[0].id}`),
    season: await get(`/shows/${shows[0].id}/seasons/1`),
    search: await get("/search?q=heat"),
    guide: await get("/guide"),
    profiles: await get("/profiles"),
  };

  // Home's hero is picked at random: hold the fixture's to the same title
  // among the candidates — or, when it isn't one of them this run, to one
  // of the same kind (a film, which has a still; a show has none).
  const home = live.home as { hero: { title: string } | null; heroes: { title: string; images: Record<string, unknown> }[] };
  const captured = fixture("home") as { hero: { title: string; images: Record<string, unknown> } | null };
  const sameKind = (hero: { images: Record<string, unknown> }) => Object.keys(captured.hero?.images ?? {}).every((key) => key in hero.images);
  home.hero = home.heroes.find((hero) => hero.title === captured.hero?.title) ?? home.heroes.find(sameKind) ?? home.hero;

  for (const [name, served] of Object.entries(live)) {
    const missing = keyPaths(fixture(name)).filter((key) => !keyPaths(served).includes(key));
    expect(missing, `${name}.json has fields the API no longer serves`).toEqual([]);
  }
});

/** Every object key path in a JSON value; array items share the path "[]". */
function keyPaths(value: unknown, prefix = ""): string[] {
  if (Array.isArray(value)) return [...new Set(value.flatMap((item) => keyPaths(item, `${prefix}[]`)))];
  if (value && typeof value === "object") {
    return Object.entries(value).flatMap(([key, child]) => [`${prefix}.${key}`, ...keyPaths(child, `${prefix}.${key}`)]);
  }
  return [];
}

// docs/PERF_PROPOSAL.md › P6: pressing Play asks for the session on the
// press, while the page is still the title's, and the player takes that one
// up — one session, never two.
test("pressing Play starts the session on the press, and plays that one", async ({ page, session }) => {
  const movies = (await (
    await page.request.get("/api/v1/movies?q=Case%20VP9", { headers: { Authorization: `Bearer ${session.token}` } })
  ).json()) as { id: string; title: string }[];
  const movie = movies.find((candidate) => candidate.title === "Case VP9 Opus")!;
  await page.goto(`/movie/${movie.id}`);

  const asked: string[] = [];
  page.on("request", (request) => {
    if (request.url().endsWith("/api/v1/playback_sessions") && request.method() === "POST") asked.push(new URL(page.url()).pathname);
  });
  await page.getByRole("button", { name: "Play", exact: true }).click();

  const video = page.locator("video");
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 10_000 }).toBeGreaterThan(0.2);
  expect(asked).toEqual([`/movie/${movie.id}`]);
});

// PROPOSAL §5.4: a finished video with nothing queued after it offers what
// to watch next over its last frame (Settings › YouTube › End screen) —
// here the other channel's video — and choosing one plays it in its place,
// still muted if the viewer muted the first.
test("a finished video offers others over its last frame, and choosing one plays it", async ({ page, session }) => {
  const videos = (await (
    await page.request.get("/api/v1/videos", { headers: { Authorization: `Bearer ${session.token}` } })
  ).json()) as { id: string; title: string; channel: { title: string } | null }[];
  const dishwasher = videos.find((candidate) => candidate.title === "The dishwasher, revisited")!;
  const other = videos.find((candidate) => candidate.channel?.title === "Cleaning Science")!;

  await page.goto(`/watch/video/${dishwasher.id}`);
  const video = page.locator("video");
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.readyState), { timeout: 10_000 }).toBeGreaterThan(0);
  await page.keyboard.press("m");
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.muted)).toBe(true);
  // The harness's files are two seconds long: it ends by itself.
  const offers = page.getByRole("region", { name: "Watch next" });
  await expect(offers).toBeVisible({ timeout: 15_000 });
  await expect(page).toHaveURL(new RegExp(`/watch/video/${dishwasher.id}$`));
  await expect(page.getByRole("button", { name: "Back" })).toBeVisible();

  await offers.getByRole("button", { name: /Cleaning Science/ }).click();
  await expect(page).toHaveURL(new RegExp(`/watch/video/${other.id}$`));
  await expect(offers).toBeHidden();
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.readyState > 0 && !element.ended), { timeout: 10_000 }).toBe(true);
  expect(await video.evaluate((element: HTMLVideoElement) => element.muted)).toBe(true);
});

// Autoplay on the end screen counts down to one not yet watched and plays
// it by itself; the switch is remembered by the browser.
test("autoplay on the end screen plays another by itself, and stays on", async ({ page, session }) => {
  const videos = (await (
    await page.request.get("/api/v1/videos", { headers: { Authorization: `Bearer ${session.token}` } })
  ).json()) as { id: string; title: string; channel: { title: string } | null }[];
  const dishwasher = videos.find((candidate) => candidate.title === "The dishwasher, revisited")!;

  await page.goto(`/watch/video/${dishwasher.id}`);
  const offers = page.getByRole("region", { name: "Watch next" });
  await expect(offers).toBeVisible({ timeout: 15_000 });
  const toggle = offers.getByRole("checkbox", { name: "Autoplay" });
  await expect(toggle).not.toBeChecked();
  await toggle.check();
  await expect(offers.getByRole("timer")).toContainText("Up next in");
  await expect(page).not.toHaveURL(new RegExp(`/watch/video/${dishwasher.id}$`), { timeout: 30_000 });
  expect(await page.evaluate(() => localStorage.getItem("stream_end_screen_autoplay"))).toBe("on");
});

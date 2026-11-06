import type { Page } from "@playwright/test";
import { expect, test } from "./support/harness";

// The TV Shows page, once it has replaced Home: Home's TV row holds a
// show's episodes ("Severance S01E01"), which a poster's /Severance/ would
// otherwise find first.
async function openTvShows(page: Page) {
  await page.getByRole("navigation").getByRole("link", { name: "TV Shows" }).click();
  await expect(page.getByRole("heading", { name: "TV Shows", level: 1 })).toBeVisible();
}

// The viewing surface over the seeded media library (lib/tasks/e2e.rake):
// real files, read by the real scanner and prober, titled from their names.

test("Home shows Continue watching and what's new", async ({ page }) => {
  await page.goto("/");
  const continuing = page.getByRole("region").filter({ has: page.getByRole("heading", { name: "Continue watching" }) });
  await expect(continuing.getByRole("link", { name: /Heat/ })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Recently added in Movies" })).toBeVisible();
  const tv = page.getByRole("region").filter({ has: page.getByRole("heading", { name: "Recently added in TV Shows" }) });
  await expect(tv.getByRole("link", { name: /Severance.*S01E01/ })).toBeVisible();
  // The hero is one of them, picked afresh each visit.
  await expect(page.getByRole("link", { name: "More info" })).toBeVisible();
  await expect(page.getByRole("button", { name: /^Play$|Resume from/ }).first()).toBeVisible();
});

test("a profile hides and reorders its home rows", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("button", { name: "Customize home" }).click();
  await page.getByRole("checkbox", { name: "Recently added in Corpus" }).uncheck();
  await expect(page.getByRole("heading", { name: "Recently added in Corpus" })).toHaveCount(0);
  await page.getByRole("button", { name: "Move Recently added in TV Shows up" }).click();
  const tvBeforeMovies = async () => {
    const headings = await page.getByRole("heading", { level: 2 }).allTextContents();
    const tv = headings.indexOf("Recently added in TV Shows");
    return tv >= 0 && tv < headings.indexOf("Recently added in Movies");
  };
  await expect.poll(tvBeforeMovies).toBe(true);
  await page.reload();
  await expect(page.getByRole("heading", { name: "Recently added in Movies" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Recently added in Corpus" })).toHaveCount(0);
  expect(await tvBeforeMovies()).toBe(true);

  // Put it back for the other tests.
  await page.getByRole("button", { name: "Customize home" }).click();
  await page.getByRole("checkbox", { name: "Recently added in Corpus" }).check();
  await page.getByRole("button", { name: "Move Recently added in Movies up" }).click();
  await expect(page.getByRole("heading", { name: "Recently added in Corpus" })).toBeVisible();
});

test("⌘K searches titles and people, forgiving typos, and goes to pages", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("navigation")).toBeVisible();
  await page.keyboard.press("ControlOrMeta+k");
  const palette = page.getByRole("dialog", { name: "Search and go" });
  const input = palette.getByRole("combobox");
  await expect(input).toBeFocused();

  await input.fill("severence");
  await expect(palette.getByRole("group", { name: "Shows" }).getByRole("option", { name: /Severance/ })).toBeVisible();

  await input.fill("pacino");
  await expect(palette.getByRole("option", { name: /Al Pacino/ })).toBeVisible();
  await input.press("Enter");
  await expect(page.getByRole("heading", { name: "Al Pacino", level: 1 })).toBeVisible();
  await expect(page.getByText("as Vincent Hanna")).toBeVisible();

  await page.keyboard.press("/");
  await page.getByRole("combobox").fill("settings");
  await page.keyboard.press("Enter");
  await expect.poll(() => page.url()).toMatch(/\/settings/);
});

test("a library is a poster wall you can filter and search", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  for (const title of ["Alien", "Heat", "Primer"]) {
    await expect(page.getByRole("link", { name: new RegExp(title) })).toBeVisible();
  }
  await page.getByLabel("Search Movies").fill("prim");
  await expect(page.getByRole("link", { name: /Heat/ })).toHaveCount(0);
  await expect(page.getByRole("link", { name: /Primer/ })).toBeVisible();
});

test("a movie resumes, plays and reports where it got to", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /Heat/ }).click();
  await expect(page.getByRole("button", { name: /Resume from/ })).toBeVisible();

  const progress = page.waitForRequest((request) => request.url().includes("/progress"));
  await page.getByRole("button", { name: "Start over" }).click();
  const video = page.locator("video");
  await expect(video).toBeVisible();
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 10_000 }).toBeGreaterThan(0.3);
  await page.keyboard.press("k");
  await progress;
  await page.getByRole("button", { name: "Back", exact: true }).click();
  await expect(page.getByRole("button", { name: /Resume from/ })).toBeVisible();
});

test("leaving the player keeps it playing in the corner", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /Heat/ }).click();
  await page.getByRole("button", { name: "Start over" }).click();
  const video = page.locator("video");
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 10_000 }).toBeGreaterThan(0.3);
  // The fixture is two seconds long; looping keeps it from ending (and the
  // corner player from closing) while the test goes about its business.
  await video.evaluate((element: HTMLVideoElement) => {
    element.loop = true;
  });

  await page.keyboard.press("?");
  await expect(page.getByRole("heading", { name: "Keyboard shortcuts" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("heading", { name: "Keyboard shortcuts" })).toHaveCount(0);
  await page.keyboard.press(">");
  expect(await video.evaluate((element: HTMLVideoElement) => element.playbackRate)).toBe(1.25);
  await page.keyboard.press("<");

  await page.keyboard.press("i");
  const mini = page.getByRole("region", { name: /Now playing: Heat/ });
  await expect(mini).toBeVisible();
  await expect(page.getByRole("button", { name: /^(Resume from|Play)/ }).first()).toBeVisible();
  const at = await video.evaluate((element: HTMLVideoElement) => element.currentTime);
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime)).not.toBe(at);

  // Browsing on doesn't stop it; expanding picks up where it is, over the
  // page browsed to, and going back to the corner finds that page again.
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(mini).toBeVisible();
  const browsed = page.url();
  await mini.hover();
  await mini.getByRole("button", { name: "Expand" }).click();
  await expect(page.getByRole("button", { name: "Back", exact: true })).toBeVisible();
  expect(page.url()).toBe(browsed);
  const expandedAt = await video.evaluate((element: HTMLVideoElement) => element.currentTime);
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime)).not.toBe(expandedAt);

  await page.keyboard.press("Escape");
  await expect(mini).toBeVisible();
  expect(page.url()).toBe(browsed);
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();

  // Expanded, its title goes to its own page.
  await mini.hover();
  await mini.getByRole("button", { name: "Expand" }).click();
  await page.getByRole("link", { name: "Heat", exact: true }).click();
  await expect.poll(() => page.url()).toMatch(/\/movie\//);
  await expect(mini).toBeVisible();
  // Escape while browsing closes the corner player — but a dialog open on
  // the page takes it first.
  await page.getByRole("complementary", { name: "Navigation" }).getByRole("button", { name: "Search" }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(mini).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(video).toHaveCount(0);
});

test("what was playing waits in the corner after a reload", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /Heat/ }).click();
  await page.getByRole("button", { name: "Start over" }).click();
  const video = page.locator("video");
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 10_000 }).toBeGreaterThan(0.3);
  await video.evaluate((element: HTMLVideoElement) => {
    element.loop = true;
  });
  await page.keyboard.press("i");
  await expect(page.getByRole("region", { name: /Now playing: Heat/ })).toBeVisible();

  // Reloaded: nothing plays by itself, but Heat is offered where it was.
  await page.reload();
  const card = page.getByRole("region", { name: "Resume Heat" });
  await expect(card).toBeVisible();
  await expect(video).toHaveCount(0);
  await card.getByRole("button", { name: "Resume Heat" }).click();
  const mini = page.getByRole("region", { name: /Now playing: Heat/ });
  await expect(mini).toBeVisible();
  await expect(card).toHaveCount(0);
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 10_000 }).toBeGreaterThan(0);

  // Closed, it's forgotten.
  await mini.hover();
  await mini.getByRole("button", { name: "Close player" }).click();
  await page.reload();
  await expect(page.getByRole("heading", { name: "Heat", level: 1 })).toBeVisible();
  await expect(card).toHaveCount(0);

  // Dismissed from the card, too.
  await page.getByRole("button", { name: "Start over" }).click();
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 10_000 }).toBeGreaterThan(0.3);
  await video.evaluate((element: HTMLVideoElement) => {
    element.loop = true;
  });
  await page.keyboard.press("i");
  await page.reload();
  await card.getByRole("button", { name: "Dismiss" }).click();
  await expect(card).toHaveCount(0);
  await page.reload();
  await expect(page.getByRole("heading", { name: "Heat", level: 1 })).toBeVisible();
  await expect(card).toHaveCount(0);

  // Purged since it was left: not offered at all, and forgotten.
  await page.getByRole("button", { name: "Start over" }).click();
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 10_000 }).toBeGreaterThan(0.3);
  await page.keyboard.press("i");
  await page.reload();
  await expect(card).toBeVisible();
  const gone = "00000000-0000-0000-0000-000000000000";
  await page.evaluate((id) => {
    for (const key of Object.keys(localStorage).filter((name) => name.startsWith("stream_last_watched:"))) {
      localStorage.setItem(key, JSON.stringify({ ...JSON.parse(localStorage.getItem(key) ?? "{}"), id }));
    }
  }, gone);
  const readable = page.waitForResponse((response) => response.url().includes(`/playback_sessions/readable?`) && response.url().includes(gone));
  await page.reload();
  expect((await readable).status()).toBe(404);
  await expect(page.getByRole("heading", { name: "Heat", level: 1 })).toBeVisible();
  await expect(card).toHaveCount(0);
  await expect.poll(() => page.evaluate(() => Object.keys(localStorage).filter((name) => name.startsWith("stream_last_watched:")).length)).toBe(0);
});

// Both change the harness profile's autoplay setting, so one at a time.
test.describe("a profile that autoplays videos", () => {
  test.describe.configure({ mode: "serial" });

  test("has one take over from what's playing", async ({ page, session }) => {
    const headers = { Authorization: `Bearer ${session.token}` };
    await page.goto("/settings?tab=viewing");
    const autoplay = page.getByRole("checkbox", { name: /Play videos as soon as they open/ });
    await expect(autoplay).not.toBeChecked();
    await autoplay.check();
    await expect(autoplay).toBeChecked();
    try {
      await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
      await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
      await page.getByRole("link", { name: /Heat/ }).click();
      await page.getByRole("button", { name: "Start over" }).click();
      const video = page.locator("video");
      await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 10_000 }).toBeGreaterThan(0.3);
      await video.evaluate((element: HTMLVideoElement) => {
        element.loop = true;
      });
      await page.keyboard.press("i");
      await expect(page.getByRole("region", { name: /Now playing: Heat/ })).toBeVisible();

      await page.getByRole("navigation").getByRole("link", { name: "YouTube", exact: true }).click();
      // The feed opens on what's unwatched, and earlier specs may have played this one.
      await page.getByRole("radio", { name: "All", exact: true }).click();
      await page.getByRole("link", { name: /dishwasher, revisited/i }).first().click();
      await expect(page.getByRole("region", { name: /Now playing: The dishwasher/ })).toBeVisible();
      await expect(page.getByRole("region", { name: /Now playing: Heat/ })).toHaveCount(0);
      await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 10_000 }).toBeGreaterThan(0);
    } finally {
      await page.request.patch("/api/v1/viewing_preferences", { headers, data: { autoplay_videos: false } });
    }
  });

  test("starts one muted when the browser won't play sound, and unmutes", async ({ page, session }) => {
    const headers = { Authorization: `Bearer ${session.token}` };
    await page.request.patch("/api/v1/viewing_preferences", { headers, data: { autoplay_videos: true } });
    try {
      await page.goto("/");
      await page.getByRole("navigation").getByRole("link", { name: "YouTube", exact: true }).click();
      await page.getByRole("radio", { name: "All", exact: true }).click();
      const href = await page.getByRole("link", { name: /dishwasher, revisited/i }).first().getAttribute("href");
      // A browser that won't play sound unasked: no autoplay, and play()
      // refused unless muted (what Safari, or a direct visit in Chrome, does).
      await page.addInitScript(() => {
        const proto = HTMLMediaElement.prototype;
        const setAttribute = Element.prototype.setAttribute;
        Element.prototype.setAttribute = function (this: Element, name: string, value: string) {
          if (this instanceof HTMLMediaElement && name.toLowerCase() === "autoplay") return;
          setAttribute.call(this, name, value);
        };
        document.addEventListener("loadstart", (e) => e.target instanceof HTMLMediaElement && (e.target.loop = true), true);
        const play = proto.play;
        proto.play = function (this: HTMLMediaElement) {
          if (!this.muted) return Promise.reject(new DOMException("blocked", "NotAllowedError"));
          return play.call(this);
        };
      });
      await page.goto(href!);
      const video = page.locator("video");
      const unmute = page.getByRole("button", { name: "Unmute", exact: true });
      await expect(unmute).toBeVisible({ timeout: 15_000 });
      await expect.poll(() => video.evaluate((e: HTMLVideoElement) => ({ muted: e.muted, playing: !e.paused }))).toEqual({ muted: true, playing: true });
      await unmute.click();
      await expect(unmute).toHaveCount(0);
      expect(await video.evaluate((e: HTMLVideoElement) => e.muted)).toBe(false);
    } finally {
      await page.request.patch("/api/v1/viewing_preferences", { headers, data: { autoplay_videos: false } });
    }
  });
});

test("Stop ends playback outright, wherever the player is", async ({ page }) => {
  const loop = () =>
    page.locator("video").evaluate((element: HTMLVideoElement) => {
      element.loop = true;
    });
  // On /watch: back to the title's page, with nothing left in the corner.
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /Heat/ }).first().click();
  await page.getByRole("button", { name: /^Play$|Resume from/ }).first().click();
  await expect(page.getByRole("button", { name: "Back", exact: true })).toBeVisible();
  await loop();
  await page.getByRole("button", { name: "Stop" }).click();
  await expect(page.getByRole("heading", { name: "Heat", level: 1 })).toBeVisible();
  await expect(page.locator("video")).toHaveCount(0);

  // Expanded from the corner over another page: that page, and no player.
  await page.getByRole("button", { name: /^Play$|Resume from/ }).first().click();
  await expect(page.getByRole("button", { name: "Back", exact: true })).toBeVisible();
  await loop();
  await page.keyboard.press("i");
  await page.getByRole("navigation").getByRole("link", { name: "Playlists" }).click();
  const mini = page.getByRole("region", { name: /Now playing: Heat/ });
  await mini.hover();
  await mini.getByRole("button", { name: "Expand" }).click();
  await page.getByRole("button", { name: "Stop" }).click();
  await expect(page.locator("video")).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Playlists", level: 1 })).toBeVisible();

  // In a video's page: the page stays, with Play to start again.
  await page.getByRole("navigation").getByRole("link", { name: "YouTube" }).click();
  await page.getByRole("region", { name: "All channels" }).getByRole("link", { name: /The dishwasher, revisited/ }).first().click();
  const player = page.getByRole("region", { name: /Now playing: The dishwasher, revisited/ });
  await expect(player).toBeVisible();
  await loop();
  await player.hover();
  await player.getByRole("button", { name: "Stop" }).click();
  await expect(page.locator("video")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Play The dishwasher, revisited" })).toBeVisible();
});

test("the corner player drags anywhere and resizes from a corner", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  // Home lists Heat too: wait for the library before choosing it.
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /Heat/ }).click();
  await page.getByRole("button", { name: "Start over" }).click();
  const video = page.locator("video");
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 10_000 }).toBeGreaterThan(0.3);
  await video.evaluate((element: HTMLVideoElement) => {
    element.loop = true;
  });
  await page.keyboard.press("i");
  const mini = page.getByRole("region", { name: /Now playing: Heat/ });
  const start = (await mini.boundingBox())!;
  expect(start.x + start.width).toBeCloseTo(1280 - 16, 0);

  // Dragging the picture moves it, and doesn't count as a click to expand.
  // (A third of the way down: the play controls sit in the bottom middle.)
  await page.mouse.move(start.x + start.width / 2, start.y + start.height / 3);
  await page.mouse.down();
  await page.mouse.move(400, 300, { steps: 5 });
  await page.mouse.up();
  const moved = (await mini.boundingBox())!;
  expect(moved.x + moved.width / 2).toBeCloseTo(400, 0);
  expect(moved.y + moved.height / 3).toBeCloseTo(300, 0);
  expect(page.url()).not.toMatch(/\/watch\//);

  // The bottom-right corner grows it, keeping 16:9 and the top-left put.
  await mini.hover();
  await page.mouse.move(moved.x + moved.width - 3, moved.y + moved.height - 8);
  await page.mouse.down();
  await page.mouse.move(moved.x + moved.width + 157, moved.y + moved.height - 8, { steps: 5 });
  await page.mouse.up();
  const grown = (await mini.boundingBox())!;
  expect(grown.width).toBeCloseTo(moved.width + 160, 0);
  expect(grown.height).toBeCloseTo((grown.width * 9) / 16, 0);
  expect(grown.x).toBeCloseTo(moved.x, 0);

  // The keyboard gets there too, and where it was left is remembered.
  await mini.focus();
  await page.keyboard.press("ArrowRight");
  expect((await mini.boundingBox())!.x).toBeCloseTo(grown.x + 24, 0);
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  expect((await mini.boundingBox())!.width).toBeCloseTo(grown.width, 0);

  // Skip back and forward either side of Pause, and the title goes to its page.
  await mini.hover();
  await expect(mini.getByRole("button", { name: "Rewind 10 seconds" })).toBeVisible();
  await expect(mini.getByRole("button", { name: "Pause" })).toBeVisible();
  const before = await video.evaluate((element: HTMLVideoElement) => element.currentTime);
  await mini.getByRole("button", { name: "Skip forward 10 seconds" }).click();
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime)).not.toBeCloseTo(before, 0);
  await mini.getByRole("link", { name: "Heat" }).click();
  await expect(page).toHaveURL(/\/movie\//);
  await expect(mini).toBeVisible();

  await mini.hover();
  await mini.getByRole("button", { name: "Close player" }).click();
  await expect(video).toHaveCount(0);
});

test("a movie page plays a chosen version, and its extras", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /Heat/ }).click();

  const extras = page.getByRole("region").filter({ has: page.getByRole("heading", { name: "Extras" }) });
  await expect(extras.getByText("Trailer")).toBeVisible();
  await expect(page.getByText("Director's Cut", { exact: true })).toBeVisible();

  const started = page.waitForRequest((request) => request.url().endsWith("/api/v1/playback_sessions") && request.method() === "POST");
  await page.getByRole("button", { name: "Play Director's Cut" }).click();
  const body = (await started).postDataJSON() as { media_file_id?: string };
  expect(body.media_file_id).toBeTruthy();
  await expect.poll(() => page.url()).toContain(`version=${body.media_file_id}`);
  await page.getByRole("button", { name: "Back", exact: true }).click();
  await page.getByRole("region", { name: /Now playing/ }).hover();
  await page.getByRole("button", { name: "Close player" }).click();

  await extras.getByRole("link", { name: /Heat/ }).click();
  await expect(page.getByText("Trailer · Heat")).toBeVisible();
  const video = page.locator("video");
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 10_000 }).toBeGreaterThan(0.3);
});

test("an admin shelves titles in a collection of their own", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /Alien/ }).click();

  await page.getByRole("button", { name: "Add to collection" }).click();
  await page.getByRole("textbox", { name: "New collection" }).fill("Friday nights");
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(page.getByRole("link", { name: "Friday nights" })).toBeVisible();

  await page.getByRole("navigation").getByRole("link", { name: "Collections" }).click();
  await page.getByRole("link", { name: /Friday nights/ }).click();
  await expect(page.getByRole("heading", { name: "Friday nights" })).toBeVisible();
  await expect(page.getByRole("link", { name: /Alien/ })).toBeVisible();

  await page.getByRole("button", { name: "Delete collection" }).click();
  await page.getByRole("button", { name: "Yes" }).click();
  await expect.poll(() => page.url()).toMatch(/\/collections$/);
  await expect(page.getByRole("link", { name: /Friday nights/ })).toHaveCount(0);
});

test("an admin corrects a title's details, which stay locked until unlocked", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /Primer/ }).click();

  const rated = page.waitForResponse((response) => response.url().endsWith("/api/v1/rating") && response.request().method() === "PUT");
  await page.getByRole("button", { name: "Rate 4 stars" }).click();
  await rated;
  await page.reload();
  await expect(page.getByRole("button", { name: "Clear your rating" })).toHaveAttribute("aria-pressed", "true");

  await page.getByRole("button", { name: "Edit details" }).click();
  await page.getByLabel("Tagline").fill("If you're watching this, it worked.");
  await page.getByLabel("Genres").fill("Science Fiction, Drama");
  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByText("If you're watching this, it worked.")).toBeVisible();
  await expect(page.getByText("Science Fiction, Drama")).toBeVisible();

  await page.getByRole("button", { name: "Edit details" }).click();
  await page.getByRole("button", { name: "Unlock tagline (let TMDB set it again)" }).click();
  await expect(page.getByRole("button", { name: "Unlock tagline (let TMDB set it again)" })).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Unlock genres (let TMDB set it again)" })).toBeVisible();
});

test("a playlist plays through in order", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /Heat/ }).click();
  await page.getByRole("button", { name: "Add to playlist" }).click();
  await page.getByRole("textbox", { name: "New playlist" }).fill("Rainy Sunday");
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("Added to Rainy Sunday.");

  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /Alien/ }).click();
  await page.getByRole("button", { name: "Add to playlist" }).click();
  await page.getByRole("button", { name: "Rainy Sunday" }).click();
  await expect(page.getByRole("status")).toHaveText("Added to Rainy Sunday.");

  await page.getByRole("navigation").getByRole("link", { name: "Playlists" }).click();
  await page.getByRole("link", { name: /Rainy Sunday/ }).click();
  await expect(page.getByRole("listitem")).toHaveCount(2);
  const started = page.waitForRequest((request) => request.url().endsWith("/api/v1/playback_sessions") && request.method() === "POST");
  await page.getByRole("button", { name: "Play all" }).click();
  expect(((await started).postDataJSON() as { playlist_id?: string }).playlist_id).toBeTruthy();

  // Heat is two seconds long; then the playlist moves on to Alien.
  await expect(page.getByText("Alien", { exact: true })).toBeVisible({ timeout: 15_000 });
  await expect.poll(() => page.url()).toMatch(/\/watch\/movie\/.+\?playlist=/);

  await page.getByRole("button", { name: "Back", exact: true }).click();
  await page.getByRole("region", { name: /Now playing/ }).hover();
  await page.getByRole("button", { name: "Close player" }).click();
});

test("a channel's video has a watch page whose timestamps play from there", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "YouTube" }).click();
  await expect(page.getByRole("heading", { name: "YouTube", level: 1 })).toBeVisible();
  await page.getByRole("complementary", { name: "Channels" }).getByRole("link", { name: /Technology Connections/ }).click();
  await page.getByRole("link", { name: "Channel page" }).click();
  await expect(page.getByRole("heading", { name: "Technology Connections", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /The dishwasher, revisited/ }).first().click();

  await expect(page.getByRole("heading", { name: "The dishwasher, revisited" })).toBeVisible();
  await expect(page.getByRole("link", { name: "https://example.com/soap" })).toHaveAttribute("target", "_blank");
  const chapters = page.getByRole("region").filter({ has: page.getByRole("heading", { name: "Chapters" }) }).or(page.locator("section", { has: page.getByRole("heading", { name: "Chapters" }) }));
  await expect(chapters.getByRole("link")).toHaveCount(3);

  // It plays in the page, and a timestamp jumps there without starting over.
  const player = page.getByRole("region", { name: /Now playing: The dishwasher, revisited/ });
  await expect(player).toBeVisible();
  const video = player.locator("video");
  await video.evaluate((element: HTMLVideoElement) => {
    element.loop = true;
  });
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 10_000 }).toBeGreaterThan(0.2);
  let restarted = false;
  page.on("request", (request) => {
    if (request.url().endsWith("/api/v1/playback_sessions") && request.method() === "POST") restarted = true;
  });
  await video.evaluate((element: HTMLVideoElement) => element.pause());
  await page.getByRole("link", { name: "0:01" }).first().click();
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime)).toBeGreaterThanOrEqual(1);
  expect(restarted).toBe(false);
  await expect(page.getByRole("heading", { name: "The dishwasher, revisited" })).toBeVisible();
});

test("a video plays in its page, at the size chosen, and carries on in the corner", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "YouTube" }).click();
  await page.getByRole("region", { name: "All channels" }).getByRole("link", { name: /The dishwasher, revisited/ }).first().click();
  const player = page.getByRole("region", { name: /Now playing: The dishwasher, revisited/ });
  const video = player.locator("video");
  await expect(player).toBeVisible();
  await video.evaluate((element: HTMLVideoElement) => {
    element.loop = true;
  });
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 10_000 }).toBeGreaterThan(0.2);
  const width = async () => (await player.boundingBox())?.width ?? 0;
  const normal = await width();
  expect(normal).toBeLessThan(1000);
  await expect(page.getByRole("heading", { name: "The dishwasher, revisited", level: 1 })).toBeVisible();

  // One button, back and forth: Full Width is across the page…
  const toggle = async (name: string) => {
    await player.hover();
    await player.getByRole("button", { name, exact: true }).click();
  };
  await toggle("Full Width (t)");
  await expect.poll(width).toBeGreaterThan(normal + 200);
  expect(await width()).toBeLessThan(1440);
  await toggle("Normal (t)");
  await expect.poll(width).toBeCloseTo(normal, 0);

  // …or the whole window, for someone who sets it to be (off until they do).
  const fillWindow = page.getByRole("checkbox", { name: "Full Width uses the full window" });
  await toggle("Settings");
  await expect(fillWindow).not.toBeChecked();
  await fillWindow.check();
  await page.keyboard.press("Escape");
  await toggle("Full Width (t)");
  await expect.poll(async () => (await player.boundingBox())?.height).toBe(900);
  await expect.poll(width).toBe(1440);
  await player.hover();
  await page.getByRole("button", { name: "Exit full window (Esc)" }).click();
  await expect.poll(width).toBeCloseTo(normal, 0);
  await toggle("Settings");
  await fillWindow.uncheck();
  await page.keyboard.press("Escape");

  // T toggles full width, as on YouTube; it sticks from one video to the next.
  await page.locator("body").click({ position: { x: 1400, y: 880 } });
  await page.keyboard.press("t");
  await expect.poll(width).toBeGreaterThan(normal + 200);
  await page.reload();
  await expect(player).toBeVisible();
  // A new element: two seconds long, it would end (and close) mid-test.
  await video.evaluate((element: HTMLVideoElement) => {
    element.loop = true;
  });
  await expect.poll(width).toBeGreaterThan(normal + 200);
  await page.keyboard.press("t");
  await expect.poll(width).toBeCloseTo(normal, 0);

  // Leaving the page keeps it playing in the corner; expanding covers the
  // page browsed to and Back finds it again; its title docks it in its page.
  await page.getByRole("navigation").getByRole("link", { name: "Subscriptions" }).click();
  await expect.poll(width).toBeLessThan(400);
  await player.hover();
  await player.getByRole("button", { name: "Expand" }).click();
  await page.getByRole("button", { name: "Back", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Subscriptions" })).toBeVisible();
  await expect.poll(width).toBeLessThan(400);
  await player.hover();
  await player.getByRole("button", { name: "Expand" }).click();
  await page.getByRole("link", { name: "The dishwasher, revisited", exact: true }).click();
  await expect.poll(() => page.url()).toMatch(/\/video\//);
  await expect.poll(width).toBeCloseTo(normal, 0);
  expect(await video.evaluate((element: HTMLVideoElement) => element.currentTime)).toBeGreaterThan(0);
});

test("the YouTube library lists its channels beside a feed that one of them narrows", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "YouTube" }).click();
  const channels = page.getByRole("complementary", { name: "Channels" });
  await expect(channels.getByRole("link", { name: /All channels/ })).toHaveAttribute("aria-current", "page");
  await expect(page.getByRole("heading", { name: "All channels", level: 2 })).toBeVisible();
  const feed = page.getByRole("region", { name: "All channels" });
  await expect(feed.getByRole("link", { name: /The dishwasher, revisited/ }).first()).toBeVisible();

  await channels.getByRole("link", { name: /Technology Connections/ }).click();
  await expect.poll(() => new URL(page.url()).searchParams.get("channel")).toBeTruthy();
  await expect(channels.getByRole("link", { name: /Technology Connections/ })).toHaveAttribute("aria-current", "page");
  await expect(page.getByRole("heading", { name: "Technology Connections", level: 2 })).toBeVisible();
  await expect(page.getByRole("region", { name: "Technology Connections" }).getByRole("link", { name: /The dishwasher, revisited/ }).first()).toBeVisible();

  // The list searches itself; All channels stays.
  await channels.getByRole("textbox").fill("nothing like it");
  await expect(channels.getByText("No channel matches.")).toBeVisible();
  await expect(channels.getByRole("link", { name: /All channels/ })).toBeVisible();
  await channels.getByRole("link", { name: /All channels/ }).click();
  await expect(page.getByRole("heading", { name: "All channels", level: 2 })).toBeVisible();
  await expect.poll(() => new URL(page.url()).searchParams.get("channel")).toBeNull();
});

// The "…" on a channel in the list. Cleaning Science is a folder's channel;
// the list is told it's followed and on YouTube, and the two admin commands
// are answered here, so nothing is polled or unfollowed for real.
test("a channel's … in the YouTube list subscribes, marks it all watched, checks, unfollows and opens its page", async ({ page, session }) => {
  // Whatever an earlier spec played of it, it starts unwatched.
  const headers = { Authorization: `Bearer ${session.token}` };
  const all = (await (await page.request.get("/api/v1/channels", { headers })).json()) as { id: string; title: string }[];
  const cleaning = all.find((channel) => channel.title === "Cleaning Science")!;
  expect((await page.request.post(`/api/v1/channels/${cleaning.id}/watched`, { headers, data: { watched: false } })).status()).toBe(204);

  await page.route(/\/api\/v1\/channels\?library_id=/, async (route) => {
    const response = await route.fetch();
    const rows = (await response.json()) as { title: string }[];
    const json = rows.map((row) => (row.title === "Cleaning Science" ? { ...row, tracked: true, url: "https://www.youtube.com/@cleaningscience" } : row));
    await route.fulfill({ response, json });
  });
  const asked: string[] = [];
  await page.route(/\/api\/v1\/channels\/[^/]+\/tracking(\/poll)?$/, async (route) => {
    asked.push(`${route.request().method()} ${new URL(route.request().url()).pathname.split("/tracking")[1] || "tracking"}`);
    await route.fulfill(route.request().method() === "POST" ? { status: 202, body: "" } : { json: {} });
  });

  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "YouTube" }).click();
  const channels = page.getByRole("complementary", { name: "Channels" });
  const row = channels.getByRole("listitem").filter({ has: page.getByRole("link", { name: /Cleaning Science/ }) });
  const more = row.getByRole("button", { name: "More for Cleaning Science" });
  const menu = page.getByRole("menu", { name: "More for Cleaning Science" });
  const open = async () => {
    await row.hover();
    await more.click();
    await expect(menu).toBeVisible();
  };

  await open();
  await expect(menu.getByRole("menuitem", { name: "Open on YouTube" })).toBeVisible();
  await menu.getByRole("menuitem", { name: "Subscribe", exact: true }).click();
  await expect(page.getByText("Subscribed to Cleaning Science")).toBeVisible();
  await open();
  await menu.getByRole("menuitem", { name: "Unsubscribe" }).click();
  await expect(page.getByText("Unsubscribed from Cleaning Science")).toBeVisible();

  await open();
  await menu.getByRole("menuitem", { name: "Mark all as watched" }).click();
  await expect(page.getByText("Cleaning Science: every video marked watched")).toBeVisible();
  await expect(row.getByLabel(/unwatched/)).toHaveCount(0);
  await open();
  await menu.getByRole("menuitem", { name: "Mark all as unwatched" }).click();
  await expect(row.getByLabel(/\d+ unwatched/)).toHaveCount(1);

  await open();
  await menu.getByRole("menuitem", { name: "Check for new videos" }).click();
  await expect(page.getByText("Checking Cleaning Science for new videos")).toBeVisible();
  await open();
  await menu.getByRole("menuitem", { name: "Unfollow" }).click();
  await expect(page.getByText(/Stopped following Cleaning Science/)).toBeVisible();
  expect(asked).toEqual(["POST /poll", "PATCH tracking"]);

  // Hiding asks first; Back leaves it be.
  await open();
  await menu.getByRole("menuitem", { name: "Hide from me…" }).click();
  await expect(menu.getByText(/^Hide from .+ everywhere\?$/)).toBeVisible();
  await expect(menu.getByRole("menuitem", { name: "Hide Cleaning Science" })).toBeVisible();
  await menu.getByRole("menuitem", { name: "Back", exact: true }).click();
  await expect(menu.getByRole("menuitem", { name: "Go to channel page" })).toBeVisible();
  await menu.getByRole("menuitem", { name: "Go to channel page" }).click();
  await expect(page.getByRole("heading", { name: "Cleaning Science", level: 1 })).toBeVisible();
});

test("an admin sets the YouTube download folder, and Add from YouTube takes only YouTube links", async ({ page }) => {
  await page.goto("/settings?tab=youtube");
  const folder = page.getByLabel("Folder");
  await folder.selectOption({ label: await folder.locator("option", { hasText: "YouTube —" }).first().innerText() });
  await page.getByRole("button", { name: "Save" }).click();
  await expect(folder).not.toHaveValue("");

  await page.getByRole("navigation").getByRole("link", { name: "YouTube" }).click();
  await page.getByRole("button", { name: "Add from YouTube" }).click();
  await page.getByRole("textbox", { name: "YouTube link" }).fill("https://vimeo.com/1");
  await page.getByRole("button", { name: "Look up" }).click();
  await expect(page.getByRole("alert")).toHaveText("That isn't a YouTube link");
  await page.getByRole("button", { name: "Close", exact: true }).click();
  await expect(page.getByRole("textbox", { name: "YouTube link" })).toHaveCount(0);
});

test("a channels library marks a channel's videos watched from its header, and one video from its card", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "YouTube" }).click();
  const channels = page.getByRole("complementary", { name: "Channels" });
  const row = channels.getByRole("listitem").filter({ has: page.getByRole("link", { name: /Cleaning Science/ }) });
  await row.getByRole("link", { name: /Cleaning Science/ }).click();
  const feed = page.getByRole("region", { name: "Cleaning Science" });

  // One card: its dot goes, and the same button takes it back.
  const title = (await feed.getByRole("link", { name: /^Unwatched/ }).first().innerText()).trim();
  const tile = feed.locator("div.group").filter({ has: page.getByRole("link", { name: title, exact: false }) }).first();
  await tile.hover();
  await tile.getByRole("button", { name: "Mark as watched", exact: true }).click();
  await expect(tile.getByRole("button", { name: "Mark as unwatched" })).toBeAttached();
  await expect(tile.getByLabel("Unwatched", { exact: true })).toHaveCount(0);
  await tile.hover();
  await tile.getByRole("button", { name: "Mark as unwatched" }).click();
  await expect(tile.getByLabel("Unwatched", { exact: true })).toHaveCount(1);

  // The whole channel, then back from its "…".
  await feed.getByRole("button", { name: "Mark all as watched" }).click();
  await expect(page.getByText("Cleaning Science: every video marked watched")).toBeVisible();
  await expect(row.getByLabel(/unwatched/)).toHaveCount(0);
  await expect(feed.getByLabel("Unwatched", { exact: true })).toHaveCount(0);
  await expect(feed.getByRole("button", { name: "Mark all as watched" })).toBeDisabled();
  await row.hover();
  await row.getByRole("button", { name: "More for Cleaning Science" }).click();
  await page.getByRole("menu", { name: "More for Cleaning Science" }).getByRole("menuitem", { name: "Mark all as unwatched" }).click();
  await expect(row.getByLabel(/\d+ unwatched/)).toHaveCount(1);
});

test("an admin narrows a channel to titles matching a pattern, and a broken one is refused", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "YouTube" }).click();
  await page.getByRole("complementary", { name: "Channels" }).getByRole("link", { name: /Technology Connections/ }).click();
  await page.getByRole("link", { name: "Channel page" }).click();
  await page.getByRole("button", { name: "Rules and downloads" }).click();

  const filter = page.getByLabel("Only titles matching");
  const save = page.getByRole("button", { name: "Save rules" });
  await filter.fill("part (");
  await save.click();
  await expect(page.getByRole("alert")).toContainText("Title filter isn't a pattern");

  await filter.fill("dishwasher|part \\d+");
  await save.click();
  await expect(page.getByRole("alert")).toHaveCount(0);
  await page.reload();
  await page.getByRole("button", { name: "Rules and downloads" }).click();
  await expect(filter).toHaveValue("dishwasher|part \\d+");

  // The seed is shared: back to every video.
  await filter.fill("");
  await save.click();
  await page.reload();
  await page.getByRole("button", { name: "Rules and downloads" }).click();
  await expect(filter).toHaveValue("");
});

test("a profile subscribes to a channel, saves a video for later and queues it next", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "YouTube" }).click();
  await expect(page.getByRole("heading", { name: "YouTube", level: 1 })).toBeVisible();
  await page.getByRole("complementary", { name: "Channels" }).getByRole("link", { name: /Technology Connections/ }).click();
  await page.getByRole("link", { name: "Channel page" }).click();
  await page.getByRole("button", { name: "Subscribe" }).click();
  await expect(page.getByRole("button", { name: "Subscribed" })).toHaveAttribute("aria-pressed", "true");

  await page.getByRole("navigation").getByRole("link", { name: "Subscriptions" }).click();
  await page.getByRole("link", { name: /The dishwasher, revisited/ }).first().click();
  await page.getByRole("button", { name: "Watch later" }).click();
  await expect(page.getByRole("button", { name: "Saved for later" })).toHaveAttribute("aria-pressed", "true");

  await page.getByRole("navigation").getByRole("link", { name: "Playlists" }).click();
  await expect(page.getByRole("link", { name: /Watch later/ })).toContainText("1 item");

  // With something playing, the video can be queued to play next.
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /Alien/ }).click();
  await page.getByRole("button", { name: /^Play$|Resume from/ }).first().click();
  // Alien's player, not the video still playing in the corner until it starts.
  await expect(page.getByRole("button", { name: "Back", exact: true })).toBeVisible();
  // Two seconds long: loop it so it's still playing when the queue is used.
  await page.locator("video").evaluate((element: HTMLVideoElement) => {
    element.loop = true;
  });
  await page.keyboard.press("i");
  await page.getByRole("navigation").getByRole("link", { name: "Subscriptions" }).click();
  const tile = page.getByRole("link", { name: /The dishwasher, revisited/ }).first();
  await tile.hover();
  await page.getByRole("button", { name: "Play next" }).first().click();
  await expect(page.getByText("The dishwasher, revisited plays next")).toBeVisible();
});

test("SponsorBlock: a sponsor read is skipped by default, and a profile can ask instead", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "YouTube" }).click();
  await expect(page.getByRole("heading", { name: "YouTube", level: 1 })).toBeVisible();
  await page.getByRole("complementary", { name: "Channels" }).getByRole("link", { name: /Technology Connections/ }).click();
  await page.getByRole("link", { name: "Channel page" }).click();
  await page.getByRole("link", { name: /The dishwasher, revisited/ }).first().click();
  // It plays in the page. Two seconds long: loop it, or it ends before anyone reads the note.
  await page.locator("video").evaluate((element: HTMLVideoElement) => {
    element.loop = true;
  });
  await expect(page.getByText("Skipped sponsor")).toBeVisible();

  await page.goto("/settings?tab=viewing");
  const sponsor = page.getByRole("radiogroup", { name: "Sponsor: what to do" });
  await sponsor.getByRole("radio", { name: "Ask" }).click();
  await expect(sponsor.getByRole("radio", { name: "Ask" })).toHaveAttribute("aria-checked", "true");
  await page.reload();
  await expect(sponsor.getByRole("radio", { name: "Ask" })).toHaveAttribute("aria-checked", "true");
});

test("search finds what was said, and the transcript plays from a line", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("navigation")).toBeVisible();
  await page.keyboard.press("ControlOrMeta+k");
  await page.getByRole("combobox").fill("hyperloop");
  const hit = page.getByRole("group", { name: "Said in" }).getByRole("option", { name: /talk about the hyperloop/ });
  await expect(hit).toContainText("The dishwasher, revisited");
  await hit.click();
  await expect.poll(() => page.url()).toMatch(/\/video\/[^/?]+$/);

  await page.getByRole("button", { name: "Transcript" }).click();
  await page.getByRole("textbox", { name: "Search the transcript" }).fill("pods");
  await expect(page.getByRole("link", { name: /And dishwasher pods/ })).toHaveAttribute("href", /\?t=1$/);
});

test("home videos sit in time, and a clip plays", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Home videos" }).click();
  const july = page.getByRole("region", { name: "July 2023" });
  await expect(july).toBeVisible();
  await july.getByRole("link").first().click();
  await expect(page.getByRole("heading", { name: /July 14, 2023|14 July 2023/ })).toBeVisible();
  await expect(page.getByText(/10:15/)).toBeVisible();
  await page.getByRole("button", { name: "Play", exact: true }).click();
  const video = page.locator("video");
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 10_000 }).toBeGreaterThan(0.2);
});

test("home videos filter by who's in them, and search finds them by place", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Home videos" }).click();
  await page.getByRole("group", { name: "People" }).getByRole("button", { name: "Ada" }).click();
  await expect(page.getByRole("group", { name: "People" }).getByRole("button", { name: "Ada" })).toHaveAttribute("aria-pressed", "true");
  await expect(page.getByRole("region", { name: "July 2023" })).toContainText("Brighton");
  await expect(page.getByLabel("Album")).toContainText("Summer 2023 (1)");

  await page.keyboard.press("ControlOrMeta+k");
  await page.getByRole("combobox", { name: /Search titles/ }).fill("brighton");
  await expect(page.getByRole("group", { name: "Home videos" }).getByRole("option")).toHaveCount(1);
});

test("a library grid loads its next page as it scrolls to the end", async ({ page }) => {
  // A library bigger than a page: 120 on the first, five more on the second.
  const pages: string[] = [];
  await page.route(/\/api\/v1\/movies\?/, async (route) => {
    const url = new URL(route.request().url());
    const number = Number(url.searchParams.get("page"));
    pages.push(String(number));
    const count = number === 1 ? 120 : number === 2 ? 5 : 0;
    const offset = (number - 1) * 120;
    await route.fulfill({
      json: Array.from({ length: count }, (_, index) => ({
        kind: "movie", id: `m${offset + index}`, title: `Film ${offset + index + 1}`, year: 2000, content_rating: null,
        runtime_minutes: 90, images: {}, progress: null, watched: false,
      })),
    });
  });
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("link", { name: /\bFilm 120\b/ })).toBeVisible();
  expect(pages).toEqual(["1"]);

  await page.getByRole("link", { name: /\bFilm 120\b/ }).scrollIntoViewIfNeeded();
  await expect(page.getByRole("link", { name: /\bFilm 125\b/ })).toBeAttached();
  expect(pages).toEqual(["1", "2"]);
  await expect(page.getByRole("button", { name: "Show more" })).toHaveCount(0);
});

test("a TMDB collection shows the whole series, the films nobody has faded", async ({ page }) => {
  await page.goto("/collections");
  await page.getByRole("link", { name: /Alien Collection/ }).click();
  await expect(page.getByRole("heading", { name: "Alien Collection" })).toBeVisible();
  await expect(page.getByText("1 of 3 in your library")).toBeVisible();
  const shelf = page.locator("main");
  await expect(shelf.getByRole("link", { name: /^Alien/ })).toHaveCount(1);
  const missing = shelf.getByRole("group", { name: /not in your library/ });
  await expect(missing).toHaveCount(2);
  await expect(missing.first()).toHaveAccessibleName("Aliens (1986): not in your library");
  await expect(missing.nth(1)).toHaveAccessibleName("Alien³ (1992): not in your library");
  await expect(missing.first()).toHaveAttribute("title", "Aliens, in the series.");
});

test("a smart collection fills itself by its rules", async ({ page }) => {
  await page.goto("/collections");
  await page.getByRole("button", { name: "New smart collection" }).click();
  await page.getByLabel("Name").fill("Newest films");
  await page.getByRole("checkbox", { name: "Shows", exact: true }).uncheck();
  await page.getByLabel("Added in the last … days").fill("30");
  await page.getByLabel("Order").selectOption("title");
  await page.getByLabel("At most").fill("2");
  await page.getByRole("button", { name: "Make it" }).click();

  await expect(page.getByRole("heading", { name: "Newest films" })).toBeVisible();
  await expect(page.getByText("Smart: fills itself by its rules")).toBeVisible();
  await expect(page.locator("main").getByRole("link", { name: /Alien/ })).toBeVisible();
  await page.getByRole("button", { name: "Delete collection" }).click();
  await page.getByRole("button", { name: "Yes" }).click();
  await expect.poll(() => page.url()).toMatch(/\/collections$/);
});

test("Stats shows what's been watched, and a profile sets its ntfy topic", async ({ page }) => {
  await page.goto("/stats");
  await expect(page.getByRole("heading", { name: "Now playing" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "History" })).toBeVisible();

  await page.goto("/settings?tab=viewing");
  await expect(page.getByText(/No ntfy server is set up yet|ntfy topic/)).toBeVisible();
});

test("an MKV plays as a stream through the transcoder", async ({ page }) => {
  // Playwright's Chromium has no H.264, so the MKV (H.264 inside) is
  // converted to... H.264, which it still can't decode. The file-level
  // proof is the Heat spec; here, the stream must at least start and the
  // decision be recorded. Real Chrome and Safari run in the playback suite.
  await page.goto("/");
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await page.getByRole("link", { name: /Primer/ }).click();
  const started = page.waitForResponse((response) => response.url().includes("/playback_sessions") && response.status() === 201);
  await page.getByRole("button", { name: "Play", exact: true }).click();
  const session = await (await started).json();
  expect(["remux", "audio_transcode", "video_transcode"]).toContain(session.method);
  expect(session.source.kind).toBe("hls");
  const playlist = await page.request.get(session.source.url);
  expect(await playlist.text()).toContain("seg-0.m4s");
  const init = await page.request.get(session.source.url.replace("index.m3u8", "init.mp4"));
  expect(init.ok()).toBe(true);
});

test("a show offers its first episode and lists the season", async ({ page }) => {
  await page.goto("/");
  await openTvShows(page);
  await page.getByRole("link", { name: /Severance/ }).click();
  await expect(page.getByRole("button", { name: "Play S01E01" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Play S01E02" })).toBeVisible();
});

test("an episode offers Skip intro, then Up next at the credits", async ({ page }) => {
  await page.goto("/");
  await openTvShows(page);
  await page.getByRole("link", { name: /Severance/ }).click();
  await page.getByRole("button", { name: "Play S01E01" }).click();

  // The episode is two seconds long and its intro 1.2: hold it still the
  // moment it appears, or a slow machine misses the whole intro.
  const video = page.locator("video");
  await video.evaluate((element: HTMLVideoElement) => element.pause());
  const skip = page.getByRole("button", { name: "Skip intro" });
  await expect(skip).toBeVisible();
  await skip.click();
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime)).toBeGreaterThanOrEqual(1.2);
  await page.keyboard.press("k");

  await expect(page.getByText("S01E02")).toBeVisible();
  await page.getByRole("button", { name: "Play now" }).click();
  await expect(page.getByText(/S01E02/).first()).toBeVisible();
  await expect.poll(() => page.url()).toMatch(/\/watch\/episode\//);
  await expect(page.getByRole("button", { name: "Skip intro" })).toHaveCount(0);
});

test("a card's … menu marks a whole show watched, or just one episode", async ({ page }) => {
  await page.goto("/");
  await openTvShows(page);
  const poster = page.getByRole("link", { name: /Severance/ });
  await poster.hover();
  await page.getByRole("button", { name: "More for Severance" }).click();
  await page.getByRole("menuitem", { name: "Mark as watched" }).click();
  await expect(page.getByText("Severance: marked watched")).toBeVisible();

  // Every episode is watched now; unmarking one leaves the rest.
  await poster.click();
  await expect(page.getByRole("button", { name: "Mark unwatched" })).toHaveCount(2);
  await page.getByRole("button", { name: "More for S01E01" }).click();
  await expect(page.getByRole("menuitem", { name: "Play", exact: true })).toBeFocused();
  await page.getByRole("menuitem", { name: "Mark as unwatched" }).click();
  await expect(page.getByRole("button", { name: "Mark watched" })).toHaveCount(1);
  await expect(page.getByRole("button", { name: "Mark unwatched" })).toHaveCount(1);

  // Leave the show as the seed had it.
  await openTvShows(page);
  await poster.hover();
  await page.getByRole("button", { name: "More for Severance" }).click();
  await page.getByRole("menuitem", { name: "Mark as watched" }).click();
  await page.getByRole("button", { name: "More for Severance" }).click();
  await page.getByRole("menuitem", { name: "Mark as unwatched" }).click();
  await expect(page.getByText("Severance: marked unwatched")).toBeVisible();

  // A movie's menu has its own commands, and a second page for playlists.
  await page.getByRole("navigation").getByRole("link", { name: "Movies" }).click();
  await page.getByRole("link", { name: /Heat/ }).hover();
  await page.getByRole("button", { name: "More for Heat" }).click();
  await expect(page.getByRole("menuitem", { name: "Save to Watch later" })).toBeVisible();
  await page.getByRole("menuitem", { name: "Add to playlist…" }).click();
  await expect(page.getByRole("menuitem", { name: "Back" })).toBeFocused();
  await expect(page.getByRole("menuitem", { name: "Watch later" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("menu")).toHaveCount(0);
});

test("the player's Related panel lists the season and plays another episode in place", async ({ page }) => {
  await page.goto("/");
  await openTvShows(page);
  await page.getByRole("link", { name: /Severance/ }).click();
  await page.getByRole("button", { name: "Play S01E01" }).click();
  const video = page.locator("video");
  await video.evaluate((element: HTMLVideoElement) => {
    element.loop = true;
  });

  await page.mouse.move(640, 360);
  await page.getByRole("button", { name: "Related" }).click();
  const panel = page.getByRole("complementary", { name: "Related" });
  await expect(panel.getByRole("heading", { name: "Season 1" })).toBeVisible();
  // The season's title goes to that season on the show's page.
  await expect(panel.getByRole("heading").getByRole("link", { name: "Season 1", exact: true })).toHaveAttribute("href", /^\/show\/[^/?]+\?season=1$/);
  await expect(panel.getByRole("listitem").getByRole("link")).toHaveCount(2);
  await expect(panel.locator('[aria-current="true"]')).toContainText("S01E01");

  const firstUrl = page.url();
  await panel.getByRole("link", { name: /S01E02/ }).click();
  await expect.poll(() => page.url()).not.toBe(firstUrl);
  await expect(page.getByText(/S01E02/).first()).toBeVisible();
  // Still open on the new episode, which is now the one marked.
  await expect(panel.locator('[aria-current="true"]')).toContainText("S01E02");

  // Escape closes the panel before it leaves the player.
  await page.keyboard.press("Escape");
  await expect(panel).toHaveCount(0);
  await expect(page).toHaveURL(/\/watch\/episode\//);
  await page.keyboard.press("r");
  await expect(panel).toBeVisible();
  await page.keyboard.press("Escape");
  await page.keyboard.press("Escape");
  await expect(page).not.toHaveURL(/\/watch\//);
  await page.getByRole("region", { name: /Now playing/ }).hover();
  await page.getByRole("button", { name: "Close player" }).click();
});

// PROPOSAL §5.4: a video put in a channel's folder by hand that Stream
// couldn't identify on YouTube for sure asks an admin under its
// description — the closest candidates, a pasted link, or "not on YouTube".
// The seeded video is identified, so the API is made to say otherwise.
test("an unidentified video offers its closest YouTube matches, a pasted link, and not on YouTube", async ({ page, session }) => {
  const videos = (await (
    await page.request.get("/api/v1/videos", { headers: { Authorization: `Bearer ${session.token}` } })
  ).json()) as { id: string; title: string }[];
  const dishwasher = videos.find((candidate) => candidate.title === "The dishwasher, revisited")!;

  await page.route("https://i.ytimg.com/**", (route) => route.fulfill({ status: 404 }));
  await page.route(new RegExp(`/api/v1/videos/${dishwasher.id}$`), async (route) => {
    const response = await route.fetch();
    await route.fulfill({
      response,
      json: {
        ...(await response.json()),
        identity: "needs_review",
        youtube_candidates: [
          { youtube_id: "aaaaaaaaaaa", title: "The Dishwasher, Revisited", duration_seconds: 2, score: 0.93, reasons: ["title matches", "length differs by 40s"] },
          { youtube_id: "bbbbbbbbbbb", title: "Dishwashers, part two", duration_seconds: 2, score: 0.61, reasons: ["title 62% alike", "same length"] },
        ],
      },
    });
  });
  const asked: unknown[] = [];
  await page.route(new RegExp(`/api/v1/videos/${dishwasher.id}/(identify|not_on_youtube)$`), async (route) => {
    const body = route.request().postDataJSON() as { url?: string } | null;
    asked.push({ path: new URL(route.request().url()).pathname.split("/").pop(), ...(body ?? {}) });
    if (body?.url === "https://youtu.be/ccccccccccc") {
      await route.fulfill({ status: 409, json: { errors: ["Toasters is already that video"] } });
      return;
    }
    await route.fulfill({ status: 202, body: "" });
  });

  await page.goto(`/video/${dishwasher.id}`);
  await expect(page.getByRole("heading", { name: "Which YouTube video is this?" })).toBeVisible();
  const matches = page.getByRole("list", { name: "Possible matches" });
  await expect(matches.getByRole("listitem")).toHaveCount(2);
  await expect(matches.getByRole("listitem").first()).toContainText("title matches · length differs by 40s");
  await expect(matches.getByRole("link", { name: "Open on YouTube" }).first()).toHaveAttribute("href", "https://www.youtube.com/watch?v=aaaaaaaaaaa");

  await matches.getByRole("listitem").nth(1).getByRole("button", { name: "This one" }).click();
  await expect.poll(() => asked).toEqual([{ path: "identify", youtube_id: "bbbbbbbbbbb" }]);

  await page.getByLabel("YouTube link").fill("https://youtu.be/ccccccccccc");
  await page.getByRole("button", { name: "Use this link" }).click();
  await expect(page.getByText("Toasters is already that video")).toBeVisible();

  await page.getByRole("button", { name: "Not on YouTube" }).click();
  await expect.poll(() => asked.at(-1)).toEqual({ path: "not_on_youtube" });
  // The page asks again a few seconds on, for the details; not of these.
  await page.unrouteAll({ behavior: "ignoreErrors" });
});

// PROPOSAL §5.4: a channel made from a folder (Cleaning Science has no
// info.json, so no YouTube id) is linked to its YouTube channel by an admin
// pasting its link — without following it. YouTube's answer is faked here.
test("an admin links a folder's channel to YouTube without following it", async ({ page, session }) => {
  const channels = (await (
    await page.request.get("/api/v1/channels", { headers: { Authorization: `Bearer ${session.token}` } })
  ).json()) as { id: string; title: string }[];
  const cleaning = channels.find((channel) => channel.title === "Cleaning Science")!;

  const tracking = {
    tracked: false, youtube_id: "UCxxxxxxxxxxxxxxxxxxxxxx", backfill: "recent", backfill_count: 10, backfill_since: null, keep_last: null,
    skip_shorts: false, skip_live: false, title_filter: null, max_height: 1080, poll_every_hours: 6, last_polled_at: null,
    last_poll_error: null, downloads: { queued: 0, downloading: 0, done: 0, skipped: 0, failed: 0, removed: 0 }, recent: [],
  };
  let linked = false;
  const asked: string[] = [];
  await page.route(new RegExp(`/api/v1/channels/${cleaning.id}/tracking/link$`), async (route) => {
    const { url } = route.request().postDataJSON() as { url: string };
    asked.push(url);
    if (url.includes("@taken")) {
      await route.fulfill({ status: 409, json: { errors: ["Technology Connections is already that channel"] } });
      return;
    }
    linked = true;
    await route.fulfill({ json: tracking });
  });
  await page.route(new RegExp(`/api/v1/channels/${cleaning.id}(\\?.*)?$`), async (route) => {
    const response = await route.fetch();
    const body = await response.json();
    await route.fulfill({ response, json: linked ? { ...body, youtube_id: tracking.youtube_id } : body });
  });
  await page.route(new RegExp(`/api/v1/channels/${cleaning.id}/tracking$`), (route) => route.fulfill({ json: tracking }));

  await page.goto(`/channel/${cleaning.id}`);
  await expect(page.getByRole("heading", { name: "Link to YouTube" })).toBeVisible();
  await page.getByLabel("Channel link").fill("youtube.com/@taken");
  await page.getByRole("button", { name: "Link", exact: true }).click();
  await expect(page.getByText("Technology Connections is already that channel")).toBeVisible();

  await page.getByLabel("Channel link").fill("https://www.youtube.com/@CleaningScience");
  await page.getByRole("button", { name: "Link", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Following on YouTube" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Link to YouTube" })).toHaveCount(0);
  expect(asked).toEqual(["youtube.com/@taken", "https://www.youtube.com/@CleaningScience"]);
  await page.unrouteAll({ behavior: "ignoreErrors" });
});

test("a show's page tucks its occasional actions into a menu, and Shuffle plays every episode", async ({ page }) => {
  await page.goto("/");
  await openTvShows(page);
  await page.getByRole("link", { name: /Severance/ }).first().click();
  await expect(page.getByRole("heading", { name: "Severance" })).toBeVisible();

  await page.getByRole("button", { name: "More for Severance" }).click();
  const menu = page.getByRole("menu", { name: "More for Severance" });
  for (const name of ["Edit details", "Change pictures", "Info", "Hide from me…"]) {
    await expect(menu.getByRole("menuitem", { name })).toBeVisible();
  }
  await menu.getByRole("menuitem", { name: "Info" }).click();
  await expect(page.getByRole("dialog", { name: "Show info" })).toBeVisible();
  await page.keyboard.press("Escape");

  await page.getByRole("button", { name: "Shuffle" }).click();
  await expect.poll(() => new URL(page.url()).pathname).toMatch(/^\/watch\/episode\//);
  // The other of the two episodes waits in Play next.
  const queued = await page.evaluate(() => JSON.parse(sessionStorage.getItem("stream_queue") ?? "[]") as { id: string }[]);
  expect(queued).toHaveLength(1);
  expect(page.url()).not.toContain(queued[0]!.id);
});

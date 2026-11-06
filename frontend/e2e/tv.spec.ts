import { expect, test } from "./support/harness";

test("a TV signs in with a code entered on a phone, and a remote gets around", async ({ page, browser, baseURL }) => {
  const tvContext = await browser.newContext({ baseURL });
  const tv = await tvContext.newPage();
  await tv.goto("/tv");
  await expect(tv).toHaveURL(/\/tv\/pair$/);
  const code = (await tv.getByLabel(/^Code /).textContent())?.trim() ?? "";
  expect(code).toMatch(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);

  await page.goto("/pair");
  await page.getByLabel("Code").fill(code);
  await page.getByRole("button", { name: "Sign in the TV" }).click();
  await expect(page.getByText(/the TV .* is signing in/)).toBeVisible();

  await expect(tv).toHaveURL(/\/tv$/, { timeout: 15_000 });
  await expect(tv.getByRole("heading", { name: "Continue watching" })).toBeVisible();

  // Focus starts on the first card; the remote moves along and down.
  const firstCard = tv.getByRole("region", { name: "Continue watching" }).getByRole("link").first();
  await expect(firstCard).toBeFocused();
  await tv.keyboard.press("ArrowDown");
  await expect(firstCard).not.toBeFocused();
  const recent = tv.getByRole("region", { name: "Recently added in Movies" });
  await recent.getByRole("link").first().focus();
  await tv.keyboard.press("Enter");
  await expect(tv).toHaveURL(/\/tv\/movie\//);
  await expect(tv.getByRole("button", { name: /Play|Resume/ }).first()).toBeFocused();
  await tv.keyboard.press("Backspace");
  await expect(tv).toHaveURL(/\/tv$/);
  await tvContext.close();
});

// Remote control (PROPOSAL §11 Phase 6): a TV on /tv listens, and something
// sent from elsewhere — the app on a phone, or an agent over MCP — starts
// playing on it.
test("a TV plays what another screen sends it", async ({ page, session }) => {
  await page.goto("/tv");
  await expect(page.getByRole("heading", { name: "Continue watching" })).toBeVisible();
  const tvKey = await page.evaluate(() => localStorage.getItem("stream_device"));

  const phone = { Authorization: `Bearer ${session.token}`, "X-Stream-Device": "playwright-phone" };
  let tvDevice: { id: string; name: string } | undefined;
  await expect
    .poll(async () => {
      const devices = (await (await page.request.get("/api/v1/remote/devices", { headers: phone })).json()) as { id: string; name: string; browser: string }[];
      const mine = await page.request.get("/api/v1/remote/this_device", { headers: { ...phone, "X-Stream-Device": tvKey ?? "" } });
      const tvId = ((await mine.json()) as { id: string }).id;
      tvDevice = devices.find((device) => device.id === tvId);
      return Boolean(tvDevice);
    }, { timeout: 15_000 })
    .toBe(true);

  // Thirty seconds long, and nobody else's: still playing when "stop" arrives,
  // and Heat's place in Continue watching is left alone.
  const clock = ((await (await page.request.get("/api/v1/movies?q=Slow%20Clock", { headers: phone })).json()) as { id: string; title: string }[]).find(
    (movie) => movie.title === "Slow Clock",
  )!;
  const sent = await page.request.post(`/api/v1/remote/devices/${tvDevice!.id}/commands`, {
    headers: phone,
    data: { kind: "play", playable_type: "movie", playable_id: clock.id },
  });
  expect(sent.status()).toBe(201);
  await expect(page).toHaveURL(new RegExp(`/watch/movie/${clock.id}`), { timeout: 10_000 });

  await page.request.post(`/api/v1/remote/devices/${tvDevice!.id}/commands`, { headers: phone, data: { kind: "stop" } });
  await expect(page).toHaveURL(/\/tv$/, { timeout: 10_000 });
});

test("a TV searches and browses a library with the remote", async ({ page }) => {
  await page.goto("/tv");
  await expect(page.getByRole("heading", { name: "Continue watching" })).toBeVisible();

  await page.getByRole("navigation", { name: "TV" }).getByRole("link", { name: "Search" }).click();
  const box = page.getByRole("searchbox", { name: "Search" });
  await expect(box).toBeFocused();
  await box.fill("heat");
  const films = page.getByRole("region", { name: "Films" });
  await expect(films.getByRole("link").first()).toBeVisible();
  // Down from the box lands on the nearest film, whichever that is.
  await page.keyboard.press("ArrowDown");
  await expect(films.locator("a:focus")).toHaveCount(1);
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/tv\/movie\//);

  await page.getByRole("navigation", { name: "TV" }).getByRole("link", { name: "Movies", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Movies", level: 1 })).toBeVisible();
  await expect(page.getByRole("link", { name: /Heat/ })).toBeVisible();

  // Channels and home videos have their own places too.
  await page.getByRole("navigation", { name: "TV" }).getByRole("link", { name: "YouTube", exact: true }).click();
  await expect(page.getByRole("heading", { name: "YouTube", level: 1 })).toBeVisible();
  await page.locator("main a[data-tv]").first().click();
  await expect(page).toHaveURL(/\/tv\/channel\//);
  await expect(page.locator("main a[href^='/watch/video/']").first()).toBeVisible();
  await page.getByRole("navigation", { name: "TV" }).getByRole("link", { name: "Home videos", exact: true }).click();
  await expect(page.locator("main a[href^='/watch/clip/']").first()).toBeVisible();
});

// Grid on the 10-foot layout (PROPOSAL §7.7): what's on first thing on
// the TV's home, and the guide driven by a remote.
test("a TV shows what's on now, and the remote gets around the guide into a channel", async ({ page }) => {
  await page.goto("/tv");
  const onNow = page.getByRole("region", { name: "On now" });
  await expect(onNow.getByRole("link", { name: /2 · Severance/ })).toBeVisible();

  await page.goto("/tv/live");
  const grid = page.getByRole("grid", { name: "Guide" });
  await expect(grid).toBeVisible();
  await expect(page.locator(":focus")).toHaveAccessibleName(/^2 Severance: .*on now$/);
  await page.keyboard.press("ArrowDown");
  await expect(page.locator(":focus")).toHaveAccessibleName(/^5 Movies: /);
  await page.keyboard.press("ArrowUp");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/live\/2$/);
  await page.keyboard.press("Escape");
  await expect(page).toHaveURL(/\/tv\/live$/);
});

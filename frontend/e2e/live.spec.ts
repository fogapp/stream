import { expect, test } from "./support/harness";

// Grid (PROPOSAL §7.7): the seed's two channels, scheduled from the
// harness library. Its programs are seconds long, so moving from one to the
// next happens during the test too.
test("the guide lists channels, tuning in plays what's on, and channel up flips", async ({ page }) => {
  await page.goto("/live");
  await expect(page.getByRole("heading", { name: "Grid" })).toBeVisible();
  const guide = page.getByRole("grid", { name: "Guide" });
  await expect(guide.getByRole("rowheader").filter({ hasText: "2" }).first()).toBeVisible();
  await expect(guide.getByRole("gridcell", { name: /^5 Movies: .*on now$/ })).toBeVisible();

  await guide.getByRole("gridcell", { name: /^2 Severance: .*on now$/ }).click();
  await expect(page).toHaveURL(/\/live\/2$/);
  const banner = page.getByTestId("channel-banner").or(page.getByTestId("live-slate"));
  await expect(banner.first()).toContainText("2");
  await expect(page.locator("video.visible")).toBeAttached({ timeout: 10_000 });

  await page.keyboard.press("ArrowUp");
  await expect(page).toHaveURL(/\/live\/5$/);
  await expect(page.getByTestId("channel-banner").or(page.getByTestId("live-slate")).first()).toContainText("Movies");

  // A typed number, then Last goes back.
  await page.keyboard.press("2");
  await expect(page).toHaveURL(/\/live\/2$/, { timeout: 5_000 });
  await page.keyboard.press("Backspace");
  await expect(page).toHaveURL(/\/live\/5$/);

  // Escape leaves for the full guide (g opens the mini guide over the picture).
  await page.keyboard.press("Escape");
  await expect(page).toHaveURL(/\/live$/);
});

test("a profile hides a channel from its guide and brings it back, and keeps favourites", async ({ page }) => {
  await page.goto("/live");
  const channelFive = page.getByRole("gridcell", { name: /^5 Movies: / }).first();
  await expect(channelFive).toBeVisible();
  await page.getByRole("button", { name: "More for channel 5" }).click();
  await page.getByRole("menuitem", { name: "Hide from my guide" }).click();
  await expect(page.getByRole("gridcell", { name: /^5 Movies: / })).toHaveCount(0);
  await page.getByRole("button", { name: "Hidden channels" }).click();
  await page.getByRole("dialog", { name: "Hidden channels" }).getByRole("button", { name: "Show again" }).click();
  await page.keyboard.press("Escape");
  await expect(channelFive).toBeVisible();

  await page.getByRole("button", { name: "More for channel 2" }).click();
  await page.getByRole("menuitem", { name: "Add to favourites" }).click();
  await page.getByRole("radio", { name: "Favourites" }).click();
  await expect(page.getByRole("gridcell", { name: /^5 Movies: / })).toHaveCount(0);
  await expect(page.getByRole("gridcell", { name: /^2 Severance: / }).first()).toBeVisible();
  await page.getByRole("button", { name: "More for channel 2" }).click();
  await page.getByRole("menuitem", { name: "Remove from favourites" }).click();
});

test("an admin opens a channel's editor from its menu in the guide", async ({ page }) => {
  await page.goto("/live");
  await page.getByRole("button", { name: "More for channel 5" }).click();
  await page.getByRole("menuitem", { name: "Edit channel" }).click();
  await expect(page).toHaveURL(/\/live\/channels\/[^/]+$/);
  await expect(page.getByRole("heading", { name: /Movies/ }).first()).toBeVisible();
});

test("the guide moves like a TV guide, and a later program offers a reminder", async ({ page }) => {
  await page.goto("/live");
  const onNow = page.getByRole("gridcell", { name: /^2 Severance: .*on now$/ });
  await onNow.focus();
  await page.keyboard.press("ArrowDown");
  await expect(page.locator(":focus")).toHaveAccessibleName(/^5 Movies: /);
  await page.keyboard.press("ArrowUp");
  await page.keyboard.press("ArrowRight");
  const later = page.locator(":focus");
  await expect(later).toHaveAccessibleName(/^2 Severance: /);
  await expect(later).not.toHaveAccessibleName(/on now$/);
  await page.keyboard.press("Enter");
  const sheet = page.getByRole("dialog");
  await expect(sheet.getByRole("button", { name: "Watch now from the start" })).toBeVisible();
  await sheet.getByRole("button", { name: "Remind me" }).click();
  await expect(sheet.getByRole("button", { name: "Don't remind me" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("gridcell", { name: /^2 Severance: / }).filter({ has: page.getByLabel("Reminder set") })).toHaveCount(1);
});

// PROPOSAL §7.7: the neighbouring channels are tuned and buffered ahead, so
// changing to one is showing another picture — measured from the key to
// the first frame.
test("changing to a channel tuned ahead is instant, and the mini guide opens over the picture", async ({ page }) => {
  await page.goto("/live/2");
  await expect(page.getByTestId("channel-banner")).toBeVisible({ timeout: 15_000 });
  const five = page.locator("video[data-state=ready]").filter({ hasNot: page.locator(".visible") });
  await expect.poll(() => five.evaluateAll((videos) => videos.some((video) => (video as HTMLVideoElement).readyState >= 2)), { timeout: 10_000 }).toBe(true);

  await page.keyboard.press("ArrowUp");
  await expect(page).toHaveURL(/\/live\/5$/);
  const tuned = page.locator("video.visible");
  await expect.poll(() => tuned.getAttribute("data-tuned-ms"), { timeout: 5_000 }).not.toBeNull();
  const ms = Number(await tuned.getAttribute("data-tuned-ms"));
  console.log(`channel change to a buffered neighbour: ${ms} ms`);
  expect(ms).toBeLessThan(500);

  await page.keyboard.press("g");
  const mini = page.getByRole("dialog", { name: "Guide" });
  await expect(mini).toBeVisible();
  await expect(page.locator(":focus")).toHaveAccessibleName(/^5 Movies: .*on now$/);
  await page.keyboard.press("ArrowUp");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/live\/2$/);
  await expect(mini).toHaveCount(0);
});

// Beside channel up and down: what every channel has on now, by number,
// to change to from the side of the picture.
test("the On now panel lists what's on by channel number, and changes channel", async ({ page }) => {
  await page.goto("/live/5");
  await expect(page.getByTestId("channel-banner")).toBeVisible({ timeout: 15_000 });
  await page.mouse.move(400, 300);
  await page.getByRole("button", { name: "On now" }).click();
  const panel = page.getByRole("complementary", { name: "On now" });
  const items = panel.getByRole("listitem");
  await expect(items).toHaveCount(2);
  await expect(items.nth(0)).toContainText("2");
  await expect(items.nth(0)).toContainText("Severance");
  await expect(items.nth(1)).toContainText("Movies");
  await expect(items.nth(1)).toContainText("Watching");

  await items.nth(0).getByRole("button").click();
  await expect(page).toHaveURL(/\/live\/2$/);
  await expect(items.nth(0)).toContainText("Watching");
  // Escape closes the panel before it leaves the channel.
  await page.keyboard.press("Escape");
  await expect(panel).toHaveCount(0);
  await expect(page).toHaveURL(/\/live\/2$/);
});

// A channel that won't tune tries again by itself before saying so, and
// can always be changed without a keyboard.
test("a channel that can't be tuned says so, offers Try again, and can still be changed", async ({ page }) => {
  let refused = 0;
  await page.route("**/api/v1/playback_sessions", (route) => {
    if (route.request().method() !== "POST") return route.fallback();
    refused += 1;
    return route.fulfill({ status: 500, contentType: "application/json", body: JSON.stringify({ errors: ["Something went wrong"] }) });
  });
  await page.goto("/live/2");
  await expect(page.getByText("This channel couldn't be tuned.")).toBeVisible({ timeout: 15_000 });
  // Channel 2 three times (the first, and two tries again), and its neighbour.
  expect(refused).toBeGreaterThanOrEqual(4);

  const before = refused;
  await page.getByRole("button", { name: "Try again" }).click();
  await expect.poll(() => refused).toBeGreaterThan(before);

  await page.unroute("**/api/v1/playback_sessions");
  await page.getByRole("button", { name: "Channel up (↑)" }).click();
  await expect(page).toHaveURL(/\/live\/5$/);
  await expect(page.getByTestId("channel-banner").or(page.getByTestId("live-slate")).first()).toContainText("Movies");
  await expect(page.getByText("This channel couldn't be tuned.")).toHaveCount(0);

  await page.getByRole("button", { name: "Back (Esc)" }).click();
  await expect(page).toHaveURL(/\/live$/);
});

test("the guide's preview plays the focused channel", async ({ page }) => {
  await page.goto("/live");
  await page.getByRole("gridcell", { name: /^2 Severance: .*on now$/ }).focus();
  const preview = page.getByTestId("guide-preview").locator("video:not([hidden])");
  await expect.poll(() => preview.evaluate((video: HTMLVideoElement) => video.readyState), { timeout: 10_000 }).toBeGreaterThanOrEqual(2);

  // Muted until its button says otherwise.
  const muted = () => preview.evaluate((video: HTMLVideoElement) => video.muted);
  expect(await muted()).toBe(true);
  await page.getByRole("button", { name: "Unmute the preview" }).click();
  await expect.poll(muted).toBe(false);
  await page.getByRole("button", { name: "Mute the preview" }).click();
  await expect.poll(muted).toBe(true);
});

test("pressing a channel in the guide's left column previews what it has on now", async ({ page }) => {
  await page.goto("/live");
  const details = page.locator("[aria-live=polite]").filter({ has: page.getByTestId("guide-preview") });
  await expect(details).toContainText("2 · Severance");

  await page.getByRole("button", { name: /^Channel 5 Movies: / }).click();
  await expect(details).toContainText("5 · Movies");
  await expect(page.getByRole("gridcell", { name: /^5 Movies: .*on now$/ })).toHaveAttribute("aria-selected", "true");
  const preview = page.getByTestId("guide-preview").locator("video:not([hidden])");
  await expect.poll(() => preview.evaluate((video: HTMLVideoElement) => video.readyState), { timeout: 10_000 }).toBeGreaterThanOrEqual(2);

  await page.getByRole("button", { name: /^Channel 2 Severance: / }).click();
  await expect(details).toContainText("2 · Severance");
});

// Back from a channel — Escape, or the Back button — the guide opens on it,
// and its preview carries on with the channel's own element, still playing.
// Chosen from the guide, the guide comes back from its cache in the same
// commit that takes the channel's page away: it still opens on the channel.
test("leaving a channel for the guide keeps it playing in the preview", async ({ page }) => {
  test.setTimeout(90_000);
  const tunes: string[] = [];
  page.on("request", (request) => {
    if (request.method() === "POST" && request.url().endsWith("/api/v1/playback_sessions")) tunes.push(request.postData() ?? "");
  });
  const details = page.locator("[aria-live=polite]").filter({ has: page.getByTestId("guide-preview") });
  const preview = page.getByTestId("guide-preview").locator("video:not([hidden])");
  const direct = () => page.goto("/live/5");
  const fromGuide = async () => {
    await page.goto("/live");
    await page.getByRole("gridcell", { name: /^5 Movies: .*on now$/ }).click();
    await expect(page).toHaveURL(/\/live\/5$/);
  };
  const escape = () => page.keyboard.press("Escape");
  const leave = [
    [direct, escape],
    [direct, () => page.getByRole("button", { name: "Back (Esc)" }).click()],
    [fromGuide, escape],
  ] as const;

  for (const [open, back] of leave) {
    await open();
    await expect(page.getByTestId("channel-banner")).toBeVisible({ timeout: 15_000 });
    const before = tunes.length;
    // The picture on screen, marked: the preview should be this very element.
    await page.locator("video.visible").evaluate((video: HTMLVideoElement) => {
      video.dataset.carried = "yes";
    });
    await page.mouse.move(400, 300);
    await back();
    await expect(page).toHaveURL(/\/live$/);
    await expect(details).toContainText("5 · Movies");
    await expect(page.getByRole("gridcell", { name: /^5 Movies: .*on now$/ })).toHaveAttribute("aria-selected", "true");
    // (The harness's files are seconds long: played, rather than still playing.)
    await expect.poll(() => preview.evaluate((video: HTMLVideoElement) => video.readyState >= 2 && video.currentTime > 0), { timeout: 10_000 }).toBe(true);
    // The channel's own element, not a new tune — and its sound with it.
    expect(tunes.slice(before)).toEqual([]);
    expect(await preview.evaluate((video: HTMLVideoElement) => video.dataset.carried)).toBe("yes");
    expect(await preview.evaluate((video: HTMLVideoElement) => video.muted)).toBe(false);
    await expect(page.getByRole("button", { name: "Mute the preview" })).toBeVisible();
  }
});

test("an admin makes a channel from the library", async ({ page }) => {
  await page.goto("/live/channels");
  await page.getByRole("link", { name: "New channel" }).first().click();
  await page.getByRole("button", { name: "Start blank" }).click();
  await page.getByLabel("Number").fill("9");
  await page.getByLabel("Name").fill("Nothing but Heat");
  // The harness's programs are seconds long: back to back, a week of them is thousands of airings.
  await page.getByLabel("Programs start").selectOption({ label: "Half hours" });
  await page.getByRole("combobox", { name: "Only these shows" }).fill("Sev");
  await page.getByRole("option", { name: /Severance/ }).click();
  await page.getByRole("button", { name: "Make channel" }).click();
  // Making a channel schedules its first three days before it answers: over
  // five seconds of the harness's seconds-long episodes on a busy machine.
  await expect(page).toHaveURL(/\/live\/channels$/, { timeout: 15_000 });
  await expect(page.getByRole("link", { name: /9\s*Nothing but Heat/ })).toBeVisible();

  // Tidy up for the other specs.
  await page.getByRole("link", { name: /9\s*Nothing but Heat/ }).click();
  await page.getByRole("button", { name: "Delete" }).click();
  await page.getByRole("button", { name: "Yes" }).click();
  await expect(page).toHaveURL(/\/live\/channels$/);
});

test("an admin programs a channel: an appointment on the clock, and the week's preview", async ({ page }) => {
  await page.goto("/live/channels/new");
  await page.getByRole("button", { name: "Start blank" }).click();
  await page.getByLabel("Number").fill("8");
  await page.getByLabel("Name").fill("Sunday nights");
  await page.getByLabel("Programs start").selectOption({ label: "Half hours" });
  await page.getByRole("button", { name: "Appointment" }).click();
  await page.getByRole("combobox", { name: "Show", exact: true }).fill("Sev");
  await page.getByRole("option", { name: /Severance/ }).click();
  await page.getByRole("button", { name: "Add", exact: true }).click();

  const band = page.getByRole("button", { name: /^Severance, Sun 20:00–21:00$/ });
  await expect(band).toBeVisible();
  await band.focus();
  await page.keyboard.press("ArrowDown");
  await expect(page.getByRole("button", { name: /^Severance, Sun 20:15–21:15$/ })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Severance" })).toBeVisible();

  await expect(page.getByTestId("preview-day").first().locator("div").first()).toBeVisible({ timeout: 10_000 });
  // Cancelling a new channel goes back to where it started from.
  await page.getByRole("button", { name: "Cancel" }).last().click();
  await expect(page.getByRole("button", { name: "Start blank" })).toBeVisible();
});

test("a new channel starts from a preset, opened in the editor to change", async ({ page }) => {
  await page.goto("/live/channels/new");
  const decade = page.getByLabel("Decade");
  await decade.selectOption({ index: 0 });
  const name = `The ${await decade.inputValue()}s`;
  await page.getByText("What aired in the decade").locator("..").getByRole("button", { name: "Make it" }).click();
  await expect(page.getByRole("heading", { name: `New channel: ${name}` })).toBeVisible();
  await expect(page.getByLabel("Name")).toHaveValue(name);
  await expect(page.getByRole("button", { name: /^Movie of the night, Mon 20:00–22:00$/ })).toBeVisible();
  await page.getByLabel("Number").fill("77");
  await page.getByRole("button", { name: "Make channel" }).click();
  const made = page.getByRole("link", { name: new RegExp(`77\\s*${name}`) });
  await expect(made).toBeVisible();

  await made.click();
  await page.getByRole("button", { name: "Delete" }).click();
  await page.getByRole("button", { name: "Yes" }).click();
  await expect(page).toHaveURL(/\/live\/channels$/);
});

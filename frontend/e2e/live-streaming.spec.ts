import { execFileSync } from "node:child_process";
import path from "node:path";
import { expect, test } from "./support/harness";

// Grid with room to move. The seed's channels air files two seconds
// long, which is nothing to go back in: for these, the seed's Long Take is
// put on channel 5 — on now, a minute and a half in — and taken off again
// after. Real Chrome, for its H.264: the film is repackaged for it.

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

test.beforeAll(() => {
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
});

test.afterAll(() => {
  if (!before) return;
  rails(`was = JSON.parse(${JSON.stringify(before)})
    Airing.unscoped.where(id: was.fetch("id")).update_all(was.except("id"))`);
});

const position = (element: HTMLVideoElement) => element.currentTime;

// A night of Grid (2026-10-01): a reload put the viewer back at live,
// with the place they'd gone back to to find again — a click at a time,
// each its own restart of the transcoder.
test("going back in a program settles into one seek, and a reload comes back to the same place", async ({ page }) => {
  test.setTimeout(90_000);
  await page.goto("/live/5");
  await expect(page.getByTestId("channel-banner")).toBeVisible({ timeout: 20_000 });
  const video = page.locator("video.visible");
  await expect.poll(() => video.evaluate(position), { timeout: 20_000 }).toBeGreaterThan(85);
  const live = await video.evaluate(position);

  // Four presses of J: one seek, forty seconds back.
  await video.evaluate((element: HTMLVideoElement) => {
    (window as unknown as { seeks: number }).seeks = 0;
    element.addEventListener("seeking", () => ((window as unknown as { seeks: number }).seeks += 1));
  });
  for (let press = 0; press < 4; press += 1) await page.keyboard.press("j");
  await expect.poll(() => video.evaluate(position), { timeout: 20_000 }).toBeLessThan(live - 30);
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => !element.seeking && element.readyState >= 3), { timeout: 20_000 }).toBe(true);
  expect(await page.evaluate(() => (window as unknown as { seeks: number }).seeks)).toBe(1);
  await page.mouse.move(400, 300);
  await expect(page.getByRole("button", { name: /Jump to live/ })).toBeVisible();

  // Pausing reports where it is; that's what a reload comes back to.
  const reported = page.waitForRequest((request) => request.url().includes("/progress"));
  await page.keyboard.press("k");
  await reported;
  const left = await video.evaluate(position);
  expect(left).toBeLessThan(live - 30);

  await page.reload();
  await expect(page.getByTestId("channel-banner")).toBeVisible({ timeout: 20_000 });
  const again = page.locator("video.visible");
  await expect.poll(() => again.evaluate((element: HTMLVideoElement) => !element.paused && element.currentTime), { timeout: 20_000 }).toBeGreaterThan(left - 1);
  // Where it was left, not where live has got to.
  expect(await again.evaluate(position)).toBeLessThan(left + 15);
  await page.mouse.move(400, 300);
  await expect(page.getByRole("button", { name: /Jump to live/ })).toBeVisible();

  // Back at live, there's nothing to come back to.
  await page.getByRole("button", { name: /Jump to live/ }).click();
  await expect.poll(() => again.evaluate(position), { timeout: 20_000 }).toBeGreaterThan(live);
  const caughtUp = page.waitForRequest((request) => request.url().includes("/progress"));
  await page.keyboard.press("k");
  await caughtUp;
  expect(await page.evaluate(() => window.sessionStorage.getItem("stream_live_place"))).toBeNull();
});

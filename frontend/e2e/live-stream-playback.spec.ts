import { readFileSync } from "node:fs";
import path from "node:path";
import type { APIRequestContext, Page } from "@playwright/test";
import { expect, test } from "./support/harness";
import { LiveSource } from "./support/liveSource";

// PROPOSAL §7.8: a web stream, added by its address, plays live through
// Stream's relay — in Chrome and in Safari's engine — says so when its
// source drops, and carries on by itself when the source is back.

const source = new LiveSource();
let api: APIRequestContext;
let libraryId = "";
let streamId = "";
let stationId = "";

test.beforeAll(async ({ playwright, session }, testInfo) => {
  await source.open();
  api = await playwright.request.newContext({
    baseURL: testInfo.project.use.baseURL,
    extraHTTPHeaders: { Authorization: `Bearer ${session.token}` },
  });
  const library = await api.post("/api/v1/libraries", { data: { library: { name: "Test streams", kind: "live" } } });
  expect(library.ok(), await library.text()).toBe(true);
  libraryId = ((await library.json()) as { id: string }).id;
  const stream = await api.post("/api/v1/live_streams", {
    data: { live_stream: { name: "Test pattern", library_id: libraryId, kind: "web", url: source.url } },
  });
  expect(stream.ok(), await stream.text()).toBe(true);
  streamId = ((await stream.json()) as { id: string }).id;
});

test.afterAll(async () => {
  if (stationId) await api.delete(`/api/v1/stations/${stationId}`);
  if (libraryId) await api.delete(`/api/v1/libraries/${libraryId}`);
  await api.dispose();
  await source.close();
});

/** The picture is moving: the element's clock runs on while it plays. */
async function playing(page: Page, selector = "video") {
  const video = page.locator(selector);
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.readyState >= 3 && !element.paused), { timeout: 30_000 }).toBe(true);
  const at = await video.evaluate((element: HTMLVideoElement) => element.currentTime);
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 15_000 }).toBeGreaterThan(at + 1);
}

test("a web stream plays live, says when its source drops, and comes back by itself", async ({ page }) => {
  test.setTimeout(180_000);
  await page.goto(`/library/${libraryId}`);
  await page.getByRole("link", { name: /Test pattern/ }).click();
  await expect(page).toHaveURL(new RegExp(`/stream/${streamId}$`));
  await playing(page);
  await page.mouse.move(300, 300);
  await expect(page.getByTestId("live-badge")).toBeVisible();

  source.stop();
  await expect(page.getByRole("status").getByText("Reconnecting…")).toBeVisible({ timeout: 60_000 });

  await source.start();
  await expect(page.getByRole("status")).toBeHidden({ timeout: 90_000 });
  await playing(page);
});

test("a Grid channel can show the stream: one program in the guide, and tuning plays it", async ({ page }) => {
  test.setTimeout(120_000);
  const made = await api.post("/api/v1/stations", { data: { number: "77", name: "Pattern TV", live_stream_id: streamId } });
  expect(made.ok(), await made.text()).toBe(true);
  stationId = ((await made.json()) as { id: string }).id;

  await page.goto("/live/77");
  // The channel on screen; its neighbours are tuned ahead, out of sight.
  await playing(page, "video.visible");
  await page.mouse.move(300, 300);
  await expect(page.getByTestId("live-badge")).toBeVisible();
  // The channel's own bar, not a Back button: the guide is a key away.
  await expect(page.getByRole("button", { name: /guide/i }).first()).toBeVisible();
});

// The Apple TV app decodes fixtures of these answers
// (clients/appletv/StreamTVTests/Fixtures): every field they have must
// still be served.
test("every live stream field the Apple TV app reads is still served", async () => {
  const fixtures = path.resolve(import.meta.dirname, "../../clients/appletv/StreamTVTests/Fixtures");
  const fixture = (name: string) => JSON.parse(readFileSync(path.join(fixtures, `${name}.json`), "utf8")) as unknown;
  const streams = await (await api.get(`/api/v1/live_streams?library_id=${libraryId}`)).json();
  const session = await (await api.post("/api/v1/playback_sessions", { data: { playable_type: "live_stream", playable_id: streamId } })).json();
  await api.delete(`/api/v1/playback_sessions/${(session as { id: string }).id}`);
  for (const [name, served] of Object.entries({ live_streams: streams, live_stream_session: session })) {
    // A fixture's stream has a still and a description; the test pattern's may not yet.
    const optional = new Set([".[].still_url", ".[].description"]);
    const missing = keyPaths(fixture(name)).filter((key) => !keyPaths(served).includes(key) && !optional.has(key));
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

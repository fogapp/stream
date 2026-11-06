import { expect, test } from "./support/harness";

// Offline downloads (PROPOSAL §11 Phase 6), in real Chrome because it
// decodes H.264: download a film from its page, lose the network, and it
// still plays from what the service worker stored; back online, where the
// viewer got to reaches the server.
test("a download plays with no network, and its progress syncs when back", async ({ page, context, session }) => {
  const headers = { Authorization: `Bearer ${session.token}` };
  const libraries = (await (await page.request.get("/api/v1/libraries", { headers })).json()) as { id: string; name: string }[];
  const corpus = libraries.find((library) => library.name === "Corpus")!;
  const movies = (await (await page.request.get(`/api/v1/movies?library_id=${corpus.id}&per=100`, { headers })).json()) as { id: string; title: string }[];
  const movie = movies.find((candidate) => candidate.title === "Case H264 AAC MP4")!;

  // The first page load installs the service worker; the second is under it.
  await page.goto(`/movie/${movie.id}`);
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.reload();
  await expect(page.getByRole("heading", { name: "Case H264 AAC MP4" })).toBeVisible();

  const created = page.waitForResponse((response) => response.url().endsWith("/api/v1/offline_downloads") && response.request().method() === "POST");
  await page.getByRole("button", { name: "Download", exact: true }).click();
  const download = (await (await created).json()) as { id: string };
  await expect(page.getByRole("link", { name: "Downloaded" })).toBeVisible({ timeout: 30_000 });

  await page.goto("/downloads");
  await expect(page.getByText("Ready")).toBeVisible();

  await context.setOffline(true);
  await page.goto(`/downloads/${download.id}`);
  const video = page.locator("video");
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 20_000 }).toBeGreaterThan(1);
  expect(await video.evaluate((element: HTMLVideoElement) => element.error?.code ?? null)).toBeNull();
  // Seeking works from storage too (byte ranges from the service worker).
  await video.evaluate((element: HTMLVideoElement) => {
    element.pause();
    element.currentTime = 5;
  });
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.readyState), { timeout: 10_000 }).toBeGreaterThan(1);

  const synced = page.waitForResponse((response) => response.url().endsWith(`/api/v1/offline_downloads/${download.id}/progress`));
  await context.setOffline(false);
  await page.evaluate(() => window.dispatchEvent(new Event("online")));
  expect((await synced).status()).toBe(200);

  // Tidy up: out of the browser and off the server.
  await page.goto("/downloads");
  await page.getByRole("button", { name: "Remove" }).click();
  await page.getByRole("button", { name: /Yes|Confirm|Remove/ }).last().click();
  await expect(page.getByText("Nothing downloaded")).toBeVisible();
});

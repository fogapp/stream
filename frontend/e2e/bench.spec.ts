import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import type { APIRequestContext, Page } from "@playwright/test";
import { expect, test } from "./support/harness";

// The playback benchmark (docs/PERF_PROPOSAL.md › P1): six minutes of 1080p
// at a real film's bitrate, played the three ways Chrome streams — the
// file repackaged, its sound converted, its picture converted — timing the
// start and far seeks each way. Only with BENCH=1, which also makes the
// seed build the files (lib/tasks/e2e.rake):
//
//   BENCH=1 BENCH_LABEL=before-pr2 npx playwright test e2e/bench.spec.ts --project=chrome
//
// Results print as a table and land in tmp/bench/<label>.json.
test.skip(!process.env.BENCH, "the benchmark runs with BENCH=1");
test.setTimeout(10 * 60_000);
// A 1080p screen, as at home: the harness's 1280×720 would have every file
// converted down to fit it.
test.use({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });

const TITLES = ["Bench Remux", "Bench Audio", "Bench Convert"] as const;
const EXPECTED: Record<(typeof TITLES)[number], string> = {
  "Bench Remux": "remux",
  "Bench Audio": "audio_transcode",
  "Bench Convert": "video_transcode",
};
const RUNS = 3;
// Where far seeks land, as a share of the film: forward past anything
// buffered, then back behind where the run started.
const SEEKS = [0.7, 0.3, 0.9] as const;

interface Result {
  title: string;
  method: string;
  startup: number[];
  seeks: number[];
}

async function benchMovies(request: APIRequestContext, token: string) {
  const headers = { Authorization: `Bearer ${token}` };
  const libraries = (await (await request.get("/api/v1/libraries", { headers })).json()) as { id: string; name: string }[];
  const bench = libraries.find((library) => library.name === "Bench");
  expect(bench, "the Bench library (seed with BENCH=1)").toBeTruthy();
  return (await (await request.get(`/api/v1/movies?library_id=${bench!.id}&per=10`, { headers })).json()) as { id: string; title: string }[];
}

const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)] ?? NaN;

async function seekTo(page: Page, share: number): Promise<number> {
  const video = page.locator("video");
  const before = await video.getAttribute("data-seek-ms");
  await video.evaluate((element: HTMLVideoElement, at) => {
    delete element.dataset.seekMs;
    element.currentTime = element.duration * at;
  }, share);
  await expect.poll(() => video.getAttribute("data-seek-ms"), { timeout: 30_000 }).not.toBeNull();
  const ms = Number(await video.getAttribute("data-seek-ms"));
  expect(ms, `a seek after ${before}`).toBeGreaterThan(0);
  // Playing again at the new place, not just arrived.
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.paused || element.readyState < 3), { timeout: 30_000 }).toBe(false);
  return ms;
}

test("time to first frame and far seeks, at home sizes", async ({ page, session }) => {
  const movies = await benchMovies(page.request, session.token);
  const results: Result[] = [];
  for (const title of TITLES) {
    const movie = movies.find((candidate) => candidate.title === title);
    expect(movie, title).toBeTruthy();
    const result: Result = { title, method: "", startup: [], seeks: [] };
    for (let run = 0; run < RUNS; run += 1) {
      const created = page.waitForResponse((response) => response.url().endsWith("/api/v1/playback_sessions") && response.request().method() === "POST");
      // Always from the top (t sends the server there too): a resume point
      // left by the last run would move where it begins.
      await page.goto(`/watch/movie/${movie!.id}?t=0.01`);
      const body = await (await created).json();
      result.method = body.method;
      const video = page.locator("video");
      await expect.poll(() => video.getAttribute("data-startup-ms"), { timeout: 60_000 }).not.toBeNull();
      result.startup.push(Number(await video.getAttribute("data-startup-ms")));
      for (const share of SEEKS) result.seeks.push(await seekTo(page, share));
      await page.request.delete(`/api/v1/playback_sessions/${body.id}`, { headers: { Authorization: `Bearer ${session.token}` } });
      // Somewhere else, so the next visit to this title is a fresh press of Play.
      await page.goto("/");
    }
    expect(result.method, title).toBe(EXPECTED[title]);
    results.push(result);
  }

  const rows = results.map((result) => ({
    title: result.title,
    method: result.method,
    startup_median_ms: median(result.startup),
    startup_ms: result.startup,
    seek_median_ms: median(result.seeks),
    seek_ms: result.seeks,
  }));
  console.table(rows.map(({ title, method, startup_median_ms, seek_median_ms }) => ({ title, method, startup_median_ms, seek_median_ms })));
  const label = process.env.BENCH_LABEL ?? "latest";
  const directory = path.resolve(import.meta.dirname, "../../tmp/bench");
  mkdirSync(directory, { recursive: true });
  writeFileSync(path.join(directory, `${label}.json`), JSON.stringify({ label, at: new Date().toISOString(), rows }, null, 2));
});

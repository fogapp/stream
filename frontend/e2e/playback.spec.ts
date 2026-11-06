import type { APIRequestContext } from "@playwright/test";
import { expect, test } from "./support/harness";

// Every file in the fixture corpus plays (PROPOSAL §11, Phase 2 exit), in
// real Chrome and in WebKit (Safari's engine): whatever the decision engine
// chose, video advances and nothing fails. Titles come from the seed's
// Corpus library (lib/tasks/e2e.rake).
const CASES = [
  "Case H264 AAC MP4",
  "Case MKV AC3 Subs",
  "Case HEVC HDR10",
  "Case AV1 Opus",
  "Case VP9 Opus",
  "Case MPEG2 TS",
  "Case Hi10P",
  "Case DTS",
  "Case TrueHD",
  "Case FLAC",
  "Case MovText",
] as const;

// Direct first (CLAUDE.md invariant 3), pinned per browser: the cheapest way
// each case can play in what these browsers report they can do. A case
// that starts costing more than this fails here, not quietly on a TV.
type Method = "direct" | "remux" | "audio_transcode" | "optimized" | "video_transcode";
const EXPECTED: Record<string, Record<(typeof CASES)[number], Method>> = {
  chrome: {
    "Case H264 AAC MP4": "direct",
    "Case MKV AC3 Subs": "remux",
    "Case HEVC HDR10": "video_transcode",
    "Case AV1 Opus": "direct",
    "Case VP9 Opus": "direct",
    "Case MPEG2 TS": "video_transcode",
    "Case Hi10P": "remux",
    "Case DTS": "audio_transcode",
    "Case TrueHD": "audio_transcode",
    "Case FLAC": "remux",
    "Case MovText": "direct",
  },
  webkit: {
    "Case H264 AAC MP4": "direct",
    "Case MKV AC3 Subs": "remux",
    "Case HEVC HDR10": "remux",
    "Case AV1 Opus": "audio_transcode",
    "Case VP9 Opus": "audio_transcode",
    "Case MPEG2 TS": "video_transcode",
    // Safari says yes to 10-bit H.264 and then can't decode it (Playback::Quirks,
    // from jellyfin-web): Apple's decoders don't do High 10. A clock that
    // advanced here was the sound alone.
    "Case Hi10P": "video_transcode",
    "Case DTS": "audio_transcode",
    "Case TrueHD": "audio_transcode",
    "Case FLAC": "remux",
    "Case MovText": "direct",
  },
};

// Twice PROPOSAL §6.4's targets: a regression fails here, a slow CI box doesn't.
const STARTUP_BUDGET_MS: Record<Method, number> = {
  direct: 1_600,
  remux: 3_000,
  audio_transcode: 3_000,
  optimized: 1_600,
  video_transcode: 6_000,
};

interface Movie {
  id: string;
  title: string;
}

// Two WebKit cases hang on the machine, not the browser: HDR10 plays as-is
// only on a display that shows HDR, and AV1 only where WebKit has a decoder
// for it (Apple silicon from M3). Anywhere else the engine rightly converts
// the video, so the expectation follows what the browser reported.
function expected(project: string, title: (typeof CASES)[number], capabilities: { video?: string[]; hdr?: string[] }): Method {
  const pinned = EXPECTED[project][title];
  if (project !== "webkit") return pinned;
  if (title === "Case HEVC HDR10" && !capabilities.hdr?.includes("hdr10")) return "video_transcode";
  if (title === "Case AV1 Opus" && !capabilities.video?.includes("av1")) return "video_transcode";
  return pinned;
}

async function corpusMovies(request: APIRequestContext, token: string): Promise<Movie[]> {
  const headers = { Authorization: `Bearer ${token}` };
  const libraries = (await (await request.get("/api/v1/libraries", { headers })).json()) as { id: string; name: string }[];
  const corpus = libraries.find((library) => library.name === "Corpus");
  expect(corpus, "the seed's Corpus library").toBeTruthy();
  return (await (await request.get(`/api/v1/movies?library_id=${corpus!.id}&per=100`, { headers })).json()) as Movie[];
}

for (const title of CASES) {
  test(`${title} plays`, async ({ page, session }) => {
    const movies = await corpusMovies(page.request, session.token);
    const movie = movies.find((candidate) => candidate.title === title);
    expect(movie, title).toBeTruthy();

    const created = page.waitForResponse((response) => response.url().endsWith("/api/v1/playback_sessions") && response.request().method() === "POST");
    await page.goto(`/watch/movie/${movie!.id}`);
    const response = await created;
    const body = await response.json();
    expect(response.status(), JSON.stringify(body)).toBe(201);
    test.info().annotations.push({ type: "decision", description: `${body.method}: ${body.decision.summary}` });
    const capabilities = (response.request().postDataJSON() as { capabilities?: { video?: string[]; hdr?: string[] } }).capabilities ?? {};
    expect(body.method, body.decision.summary).toBe(expected(test.info().project.name, title, capabilities));
    // Anything but direct play says why, in words (the admin page and the player's info show it).
    if (body.method !== "direct") expect(body.decision.summary).toMatch(/isn't supported|can't|on a screen/);

    const video = page.locator("video");
    await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 20_000 }).toBeGreaterThan(0.5);
    await expect(page.getByText(/couldn't (play|be played)/i)).toHaveCount(0);
    expect(await video.evaluate((element: HTMLVideoElement) => element.error?.code ?? null)).toBeNull();

    // From the session being asked for to the first frame (PROPOSAL §6.4,
    // docs/PERF_PROPOSAL.md › P1), with room for a busy CI machine.
    const startup = Number(await video.getAttribute("data-startup-ms"));
    test.info().annotations.push({ type: "startup", description: `${startup} ms` });
    console.log(`${test.info().project.name} ${title} (${body.method}): ${startup} ms`);
    expect(startup, "startup ms").toBeGreaterThan(0);
    expect(startup, `started in ${startup} ms`).toBeLessThan(STARTUP_BUDGET_MS[body.method as Method]);

    // End the session so a video conversion doesn't count against the cap
    // for the next case.
    await page.request.delete(`/api/v1/playback_sessions/${body.id}`, { headers: { Authorization: `Bearer ${session.token}` } });
  });
}

import { copyFileSync, mkdirSync, renameSync, rmSync } from "node:fs";
import path from "node:path";
import type { APIRequestContext, Page } from "@playwright/test";
import { HARNESS_USER, expect, test } from "./support/harness";

// What changes the library or the household (playwright.config.ts runs this
// after every spec that reads the seed as it was): files that move, arrive,
// or can't be read; a library added in Settings; a member who joins; a
// passkey. Everything here crosses the whole stack — disk, scanner, prober,
// jobs, API and SPA.

const REPO = path.resolve(import.meta.dirname, "../..");
const MEDIA = path.join(REPO, "tmp", "e2e-media");
const FIXTURES = path.join(REPO, "spec", "fixtures", "media");

interface Library {
  id: string;
  name: string;
  roots: string[];
}

interface MediaFile {
  id: string;
  path: string;
  state: string;
}

function api(request: APIRequestContext, token: string) {
  const headers = { Authorization: `Bearer ${token}` };
  return {
    get: async <T>(url: string) => (await (await request.get(`/api/v1${url}`, { headers })).json()) as T,
    post: (url: string, data?: object) => request.post(`/api/v1${url}`, { headers, data }),
  };
}

async function libraryNamed(request: APIRequestContext, token: string, name: string): Promise<Library> {
  const libraries = await api(request, token).get<Library[]>("/libraries");
  const library = libraries.find((candidate) => candidate.name === name);
  expect(library, name).toBeTruthy();
  return library!;
}

async function movieNamed(request: APIRequestContext, token: string, title: string): Promise<{ id: string; title: string }> {
  const movies = await api(request, token).get<{ id: string; title: string }[]>(`/movies?q=${encodeURIComponent(title)}`);
  const movie = movies.find((candidate) => candidate.title === title);
  expect(movie, title).toBeTruthy();
  return movie!;
}

test("a file that can't be read says so, where an admin looks", async ({ page, session }) => {
  // Seeded into the Unreadable library from the truncated fixture: probed, and broken.
  const unreadable = await libraryNamed(page.request, session.token, "Unreadable");
  const broken = await api(page.request, session.token).get<MediaFile[]>(`/media_files?library_id=${unreadable.id}&state=broken`);
  expect(broken).toHaveLength(1);

  await page.goto("/settings?tab=libraries");
  await expect(page.getByText("1 can't be read")).toBeVisible();

  await page.goto(`/files/${broken[0].id}`);
  await expect(page.getByText("Last error")).toBeVisible();
  await expect(page.getByText(/Can't be read/i).first()).toBeVisible();

  await page.goto("/activity");
  await expect(page.getByText(/Couldn't read Broken Film \(1999\)\.mkv/)).toBeVisible();
});

test("a file moved on disk keeps its watch state and its id", async ({ page, session }) => {
  const client = api(page.request, session.token);
  const movie = await movieNamed(page.request, session.token, "Moving Picture");
  expect((await client.post("/watch_states", { playable_type: "movie", playable_id: movie.id, watched: true })).ok()).toBe(true);
  const corpus = await libraryNamed(page.request, session.token, "Corpus");
  const [before] = await client.get<MediaFile[]>(`/media_files?library_id=${corpus.id}&q=Moving%20Picture`);

  // What Radarr does on a rename: same bytes, new folder.
  const from = path.join(MEDIA, "corpus", "Moving Picture (2001)");
  const to = path.join(MEDIA, "corpus", "Moving Picture (2001) [Remastered]");
  rmSync(to, { recursive: true, force: true });
  renameSync(from, to);
  expect((await client.post(`/libraries/${corpus.id}/scan`)).ok()).toBe(true);

  await expect
    .poll(async () => (await client.get<MediaFile[]>(`/media_files?library_id=${corpus.id}&q=Remastered`))[0], { timeout: 30_000 })
    .toMatchObject({ id: before.id, state: "probed" });

  await page.goto(`/movie/${movie.id}`);
  await expect(page.getByRole("button", { name: "Mark unwatched" })).toBeVisible();
  await page.goto("/activity");
  await expect(page.getByText(/moved from .*Moving Picture \(2001\) to .*\[Remastered\]/)).toBeVisible();
});

test("Sonarr's webhook brings a new show in, ready to play", async ({ page, session }) => {
  const client = api(page.request, session.token);
  const tv = await libraryNamed(page.request, session.token, "TV Shows");
  // Sonarr sees its own mount; the mapping says where that is here.
  await client.post("/arr_webhook/path_mappings", { path_mapping: { remote_prefix: "/sonarr/tv", local_prefix: tv.roots[0] } });
  // Sonarr calls Rails itself (not through the SPA's dev proxy), at the URL Settings shows.
  const webhook = await client.get<{ url: string }>("/arr_webhook");

  const folder = path.join(tv.roots[0], "Slow Horses (2022)", "Season 01");
  mkdirSync(folder, { recursive: true });
  copyFileSync(path.join(FIXTURES, "vp9_opus.webm"), path.join(folder, "Slow Horses - S01E01.webm"));
  const hook = await page.request.post(webhook.url, {
    data: {
      eventType: "Download",
      series: { title: "Slow Horses", path: "/sonarr/tv/Slow Horses (2022)" },
      episodeFile: { path: "/sonarr/tv/Slow Horses (2022)/Season 01/Slow Horses - S01E01.webm" },
    },
  });
  expect(hook.status()).toBe(200);

  // The webhook starts a scan; the episode is read and the show made in the background.
  await expect.poll(async () => (await client.get<{ title: string }[]>("/shows?q=Slow%20Horses")).length, { timeout: 30_000 }).toBe(1);
  await page.goto(`/library/${tv.id}`);
  await page.getByRole("link", { name: /Slow Horses/ }).click();
  await expect(page.getByRole("heading", { name: "Slow Horses", level: 1 })).toBeVisible();
  await page.getByRole("button", { name: /^Play/ }).first().click();
  const video = page.locator("video");
  await expect.poll(() => video.evaluate((element: HTMLVideoElement) => element.currentTime), { timeout: 15_000 }).toBeGreaterThan(0.3);
});

test("an admin adds a library in Settings: a wrong folder is caught, a right one is scanned", async ({ page, session }) => {
  const root = path.join(MEDIA, "added");
  rmSync(root, { recursive: true, force: true });
  mkdirSync(path.join(root, "Paddington (2014)"), { recursive: true });
  copyFileSync(path.join(FIXTURES, "vp9_opus.webm"), path.join(root, "Paddington (2014)", "Paddington (2014).webm"));

  await page.goto("/settings?tab=libraries");
  await page.getByRole("button", { name: "Add library" }).first().click();
  await page.getByLabel("Name").fill("Family films");
  const folder = page.getByRole("textbox", { name: "Folder path" });
  await folder.fill("/definitely/not/mounted");
  await folder.blur();
  await expect(page.getByText(/isn't visible to Stream|doesn't exist|not found/i).first()).toBeVisible();
  await page.getByRole("button", { name: "Add library" }).last().click();
  await expect(page.getByRole("alert").or(page.getByText(/isn't visible to Stream/i)).first()).toBeVisible();

  await folder.fill(root);
  await folder.blur();
  await page.getByRole("button", { name: "Add library" }).last().click();
  const nav = page.getByRole("navigation");
  await expect(nav.getByRole("link", { name: "Family films" })).toBeVisible();
  // Saving starts a scan; the file is read, then matched, in the background.
  await expect.poll(async () => (await api(page.request, session.token).get<{ title: string }[]>("/movies?q=Paddington")).length, {
    timeout: 30_000,
  }).toBe(1);
  await nav.getByRole("link", { name: "Family films" }).click();
  await expect(page.getByRole("link", { name: /Paddington/ })).toBeVisible();

  // Leave the household as the seed made it.
  const added = await libraryNamed(page.request, session.token, "Family films");
  await page.request.delete(`/api/v1/libraries/${added.id}`, { headers: { Authorization: `Bearer ${session.token}` } });
});

test("someone invited joins with the code, as a member who can't run the place", async ({ page, browser }) => {
  await page.goto("/settings?tab=users");
  await page.getByRole("button", { name: "Create invite code" }).click();
  const code = ((await page.locator("code").last().textContent()) ?? "").trim();
  expect(code.length).toBeGreaterThan(5);

  const guest = await browser.newContext();
  const joiner = await guest.newPage();
  await joiner.goto("/login");
  await joiner.getByRole("button", { name: "Have an invite code?" }).click();
  await joiner.getByLabel("Invite code").fill(code);
  await joiner.getByLabel("Your name").fill("Sam Joiner");
  await joiner.getByLabel("Email").fill(`sam-${Date.now()}@example.com`);
  await joiner.getByLabel("Password").fill("passwordpassword");
  await joiner.getByRole("button", { name: "Join" }).click();
  await expect(joiner.getByRole("navigation").getByRole("link", { name: "Movies" })).toBeVisible();

  await joiner.goto("/settings");
  await expect(joiner.getByRole("tab", { name: "General" })).toBeVisible();
  for (const adminTab of ["Background jobs", "Transcoders", "Profiles"]) {
    await expect(joiner.getByRole("tab", { name: adminTab })).toHaveCount(0);
  }

  // The code was for one person.
  const again = await guest.request.post("/api/v1/invites/accept", {
    data: { code, name: "Second", email: `second-${Date.now()}@example.com`, password: "passwordpassword" },
  });
  expect(again.status()).toBe(422);
  await guest.close();
});

// WebAuthn needs a domain for its relying party, so this one browses as
// localhost (the harness's Rails runs with STREAM_WEBAUTHN_RP_ID=localhost)
// with Chrome's virtual authenticator standing in for a fingerprint.
test("a passkey is enrolled in Settings and signs in on its own", async ({ browser, baseURL }) => {
  const origin = baseURL!.replace("127.0.0.1", "localhost");
  const context = await browser.newContext({ baseURL: origin });
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable");
  await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true,
      automaticPresenceSimulation: true },
  });

  await signIn(page);
  await page.goto("/settings?tab=users");
  await page.getByLabel("Nickname").fill("Playwright key");
  await page.getByRole("button", { name: "Add a passkey" }).click();
  await expect(page.getByText("Playwright key")).toBeVisible();

  await page.evaluate(() => localStorage.clear());
  await page.goto("/login");
  await page.getByRole("button", { name: "Sign in with a passkey" }).click();
  await expect(page.getByRole("navigation").getByRole("link", { name: "Movies" })).toBeVisible();

  // Tidy: the seed's admin has no passkey.
  await page.goto("/settings?tab=users");
  const key = page.getByRole("listitem").filter({ hasText: "Playwright key" });
  await key.getByRole("button", { name: "Remove" }).click();
  await key.getByRole("button", { name: "Yes" }).click();
  await expect(page.getByText("Playwright key")).toHaveCount(0);
  await context.close();
});

async function signIn(page: Page) {
  await page.goto("/login");
  await page.getByLabel("Email").fill(HARNESS_USER.email);
  await page.getByLabel("Password").fill(HARNESS_USER.password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.getByRole("navigation").getByRole("link", { name: "Movies" })).toBeVisible();
}

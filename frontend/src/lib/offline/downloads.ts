import { api, ApiError } from "@/api/client";
import { capabilityProfile, deviceKey } from "@/lib/capabilities";
import { deleteItem, getItem, lastProfileId, listItems, putItem, updateItem, type OfflineItem } from "./store";

/** OfflineDownloadSerializer — what asking to download returns. */
export interface OfflineDownloadInfo {
  id: string;
  playable: { type: string; id: string };
  title: string;
  subtitle: string | null;
  back_path: string;
  size: number;
  mime_type: string;
  duration_seconds: number | null;
  optimized: boolean;
  expires_at: string;
  created_at: string;
  resume_at: number;
  markers: { kind: "intro" | "recap" | "credits"; start: number; end: number }[];
  skip: { intro: boolean; recap: boolean; credits: boolean };
  next_episode_id: string | null;
  file_url: string | null;
  poster_url: string | null;
  subtitles: { id: string; language: string | null; label: string; forced: boolean; url: string }[];
}

const DOWNLOADS = "stream-downloads-v1";

interface BackgroundFetchRegistration extends EventTarget {
  downloaded: number;
  downloadTotal: number;
}
interface BackgroundFetchManager {
  fetch(id: string, requests: string[], options: { title: string; downloadTotal?: number; icons?: { src: string; sizes: string; type: string }[] }): Promise<BackgroundFetchRegistration>;
  get(id: string): Promise<BackgroundFetchRegistration | undefined>;
}

/** Downloads need a service worker, which needs HTTPS (or localhost). */
export function offlineSupported(): boolean {
  return typeof window !== "undefined" && window.isSecureContext && "serviceWorker" in navigator && "caches" in window && "indexedDB" in window;
}

export function registerServiceWorker() {
  if (!offlineSupported()) return;
  void navigator.serviceWorker.register("/sw.js").catch(() => undefined);
}

export class DownloadError extends Error {}

/**
 * Save a title into this browser. The server picks what plays here as-is
 * (the original or its optimized version) or says why it can't; the
 * poster comes down straight away, subtitles as the server has them out,
 * the film by Background Fetch where the browser has it, so closing the
 * tab doesn't stop it.
 */
export async function startDownload(playable: { type: string; id: string }, profileId: string | null): Promise<OfflineItem> {
  const info = await api.post<OfflineDownloadInfo>("/offline_downloads", {
    playable_type: playable.type,
    playable_id: playable.id,
    capabilities: capabilityProfile(),
    device_key: deviceKey(),
  });
  if (!info.file_url) throw new DownloadError("The server didn't send a link");

  const estimate = await navigator.storage?.estimate?.();
  if (estimate?.quota !== undefined && estimate.usage !== undefined && estimate.quota - estimate.usage < info.size) {
    await api.delete(`/offline_downloads/${info.id}`).catch(() => undefined);
    throw new DownloadError("There isn't room for it in this browser's storage.");
  }
  // Ask not to be the first thing evicted when the disk fills up.
  await navigator.storage?.persist?.().catch(() => false);

  const item: OfflineItem = {
    id: info.id,
    profileId,
    playable: info.playable,
    title: info.title,
    subtitle: info.subtitle,
    backPath: info.back_path,
    size: info.size,
    mimeType: info.mime_type,
    durationSeconds: info.duration_seconds,
    optimized: info.optimized,
    expiresAt: info.expires_at,
    createdAt: new Date().toISOString(),
    state: "downloading",
    received: 0,
    error: null,
    subtitles: info.subtitles.map(({ id, label, language, forced }) => ({ id, label, language, forced })),
    hasPoster: false,
    markers: info.markers,
    skip: info.skip,
    nextEpisodeId: info.next_episode_id,
    position: info.resume_at,
    positionUpdatedAt: null,
    positionSyncedAt: null,
  };
  await putItem(item);

  // Not waited on: a track the server is still taking out of the file is
  // asked for again a while (fetchSubtitle), and the film shouldn't wait.
  void (async () => {
    for (const track of info.subtitles) await fetchSubtitle(info.id, track.id, track.url).catch(() => undefined);
  })();

  const cache = await caches.open(DOWNLOADS);
  try {
    if (info.poster_url) {
      const response = await fetch(info.poster_url);
      if (response.ok) {
        await cache.put(`/offline/${info.id}/poster`, response);
        item.hasPoster = true;
        await putItem(item);
      }
    }
  } catch {
    // Subtitles and the poster are extras; the film is what matters.
  }

  const registration = await navigator.serviceWorker.ready;
  const background = (registration as ServiceWorkerRegistration & { backgroundFetch?: BackgroundFetchManager }).backgroundFetch;
  // Only with permission already given: asked-for, Chrome starts it paused
  // until someone notices a prompt, and the download just sits there.
  if (background && (await backgroundFetchGranted())) {
    const fetch = await background.fetch(info.id, [info.file_url], {
      title: info.title,
      downloadTotal: info.size,
      icons: [{ src: "/icon-192.png", sizes: "192x192", type: "image/png" }],
    });
    watchBackground(info.id, fetch);
  } else {
    void fetchInPage(info.id, info.file_url, info.mime_type, info.size);
  }
  return item;
}

async function backgroundFetchGranted(): Promise<boolean> {
  try {
    const status = await navigator.permissions.query({ name: "background-fetch" as PermissionName });
    return status.state === "granted";
  } catch {
    return false;
  }
}

function watchBackground(id: string, registration: BackgroundFetchRegistration) {
  let last = 0;
  registration.addEventListener("progress", () => {
    const now = Date.now();
    if (now - last < 1000) return;
    last = now;
    void updateItem(id, { received: registration.downloaded });
  });
}

const SUBTITLE_ATTEMPTS = 30;
const SUBTITLE_WAIT_MAX_SECONDS = 60;

/**
 * One subtitle track into the cache. One not taken out of the file yet is
 * a 503 with Retry-After while the server's job reads it: ask again then,
 * for a while, unless the download has been removed meanwhile. Anything
 * else that isn't the track leaves it out; subtitles are an extra.
 */
export async function fetchSubtitle(id: string, trackId: string, url: string, wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))): Promise<boolean> {
  for (let attempt = 0; attempt < SUBTITLE_ATTEMPTS; attempt++) {
    const response = await fetch(url);
    if (!(await getItem(id))) return false;
    if (response.ok) {
      const cache = await caches.open(DOWNLOADS);
      await cache.put(`/offline/${id}/subtitles/${trackId}.vtt`, response);
      return true;
    }
    if (response.status !== 503) return false;
    const after = Number(response.headers.get("Retry-After"));
    await wait(Math.min(Number.isFinite(after) && after > 0 ? after : 10, SUBTITLE_WAIT_MAX_SECONDS) * 1000);
  }
  return false;
}

/** Without Background Fetch: stream it into the cache from this tab. */
async function fetchInPage(id: string, url: string, mimeType: string, size: number) {
  try {
    const response = await fetch(url);
    if (!response.ok || !response.body) throw new Error(`HTTP ${response.status}`);
    let received = 0;
    let last = 0;
    const counted = response.body.pipeThrough(
      new TransformStream<Uint8Array, Uint8Array>({
        transform(chunk, controller) {
          received += chunk.byteLength;
          const now = Date.now();
          if (now - last > 1000) {
            last = now;
            void updateItem(id, { received });
          }
          controller.enqueue(chunk);
        },
      }),
    );
    const cache = await caches.open(DOWNLOADS);
    await cache.put(`/offline/${id}/file`, new Response(counted, { headers: { "Content-Type": mimeType, "Content-Length": String(size) } }));
    await updateItem(id, { state: "done", received, error: null });
  } catch (error) {
    await updateItem(id, { state: "failed", error: error instanceof Error ? error.message : "The download failed" });
  }
}

/** Gone from this browser, and its link revoked when the server can be told. */
export async function removeDownload(id: string): Promise<void> {
  const registration = await navigator.serviceWorker?.ready;
  const background = (registration as (ServiceWorkerRegistration & { backgroundFetch?: BackgroundFetchManager }) | undefined)?.backgroundFetch;
  const running = await background?.get(id).catch(() => undefined);
  await (running as unknown as { abort?: () => Promise<boolean> } | undefined)?.abort?.();
  const cache = await caches.open(DOWNLOADS);
  for (const key of await cache.keys()) {
    if (new URL(key.url).pathname.startsWith(`/offline/${id}/`)) await cache.delete(key);
  }
  await deleteItem(id);
  await api.delete(`/offline_downloads/${id}`).catch(() => undefined);
}

/** Where the viewer got to offline, kept for the server. */
export async function savePosition(id: string, position: number) {
  await updateItem(id, { position, positionUpdatedAt: new Date().toISOString() });
}

/**
 * Tell the server what was watched offline, as of when (on start and on
 * coming back online). A download the server no longer knows is skipped.
 */
export async function syncPositions(): Promise<void> {
  if (!navigator.onLine) return;
  for (const item of await listItems()) {
    if (!item.positionUpdatedAt || (item.positionSyncedAt && item.positionSyncedAt >= item.positionUpdatedAt)) continue;
    try {
      await api.post(`/offline_downloads/${item.id}/progress`, { position: item.position, watched_at: item.positionUpdatedAt });
      await updateItem(item.id, { positionSyncedAt: new Date().toISOString() });
    } catch (error) {
      if (error instanceof ApiError && error.status === 404) await updateItem(item.id, { positionSyncedAt: new Date().toISOString() });
    }
  }
}

/** This profile's downloads (or every one here, when it isn't known). */
export async function visibleItems(): Promise<OfflineItem[]> {
  const profileId = lastProfileId();
  const items = await listItems();
  return profileId ? items.filter((item) => item.profileId === null || item.profileId === profileId) : items;
}

export { getItem, listItems };

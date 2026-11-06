/* Stream's service worker (PROPOSAL §11 Phase 6: offline downloads).
 *
 * Three jobs, nothing else:
 *   1. Keep the app itself around for when there's no network: the page
 *      and every script and stylesheet it loads are network-first, with the
 *      last good copy as the fallback. Nothing the API or media surfaces
 *      answer is kept.
 *   2. Finish downloads with Background Fetch, so a film keeps coming down
 *      with the tab closed (Chrome); src/lib/offline/downloads.ts falls back
 *      to fetching in the page elsewhere.
 *   3. Serve what was downloaded at /offline/<id>/…, with byte ranges, so a
 *      <video> seeks in it like in anything else.
 *
 * Plain JavaScript and no build step: it must be served from the root, and
 * it must not change name between releases.
 */

const SHELL = "stream-shell-v1";
const DOWNLOADS = "stream-downloads-v1";
const DB_NAME = "stream-offline";
const STORE = "downloads";
const CHANNEL = "stream-downloads";
// Old content-hashed assets pile up across releases; past this many, the
// oldest go.
const SHELL_LIMIT = 400;
const LIVE = ["/api/", "/media/", "/artwork/", "/up", "/hooks/", "/fog/", "/rails/"];

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (url.pathname.startsWith("/offline/")) {
    event.respondWith(fromDownloads(request, url));
  } else if (request.mode === "navigate") {
    event.respondWith(page(request));
  } else if (!LIVE.some((prefix) => url.pathname.startsWith(prefix))) {
    event.respondWith(asset(request));
  }
});

async function page(request) {
  const cache = await caches.open(SHELL);
  try {
    const response = await fetch(request);
    if (response.ok && (response.headers.get("content-type") || "").includes("text/html")) {
      await cache.put("/", response.clone());
    }
    return response;
  } catch (error) {
    const shell = await cache.match("/");
    if (shell) return shell;
    throw error;
  }
}

async function asset(request) {
  const cache = await caches.open(SHELL);
  try {
    const response = await fetch(request);
    // no-store is the server's recovery script for a bundle it no longer
    // has (StaleAssetsController): never keep it under the old name.
    const storable = !(response.headers.get("cache-control") || "").includes("no-store");
    if (response.ok && response.type === "basic" && storable) {
      await cache.put(request, response.clone());
      const keys = await cache.keys();
      for (const stale of keys.slice(0, Math.max(0, keys.length - SHELL_LIMIT))) await cache.delete(stale);
    }
    return response;
  } catch (error) {
    const cached = await cache.match(request);
    if (cached) return cached;
    throw error;
  }
}

async function fromDownloads(request, url) {
  const cache = await caches.open(DOWNLOADS);
  const cached = await cache.match(url.pathname);
  if (!cached) return new Response("Not downloaded", { status: 404 });

  const range = /^bytes=(\d*)-(\d*)$/.exec(request.headers.get("range") || "");
  if (!range) return cached;

  const blob = await cached.blob();
  const size = blob.size;
  let start = range[1] === "" ? size - Number(range[2]) : Number(range[1]);
  let end = range[1] === "" || range[2] === "" ? size - 1 : Math.min(Number(range[2]), size - 1);
  start = Math.max(0, start);
  if (start > end || start >= size) {
    return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${size}` } });
  }
  end = Math.max(start, end);
  return new Response(blob.slice(start, end + 1), {
    status: 206,
    headers: {
      "Content-Type": cached.headers.get("content-type") || "application/octet-stream",
      "Content-Range": `bytes ${start}-${end}/${size}`,
      "Content-Length": String(end - start + 1),
      "Accept-Ranges": "bytes",
    },
  });
}

// Background Fetch: only the film itself comes this way (the page fetched
// its subtitles and poster already); on success it's filed under the
// download's /offline/<id>/file.
self.addEventListener("backgroundfetchsuccess", (event) => {
  event.waitUntil(
    (async () => {
      const registration = event.registration;
      const cache = await caches.open(DOWNLOADS);
      const records = await registration.matchAll();
      for (const record of records) {
        const response = await record.responseReady;
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        await cache.put(`/offline/${registration.id}/file`, response);
      }
      await update(registration.id, { state: "done", received: registration.downloaded, error: null });
      await event.updateUI({ title: "Saved for offline" });
    })().catch((error) => update(event.registration.id, { state: "failed", error: String(error) })),
  );
});

self.addEventListener("backgroundfetchfail", (event) => {
  event.waitUntil(update(event.registration.id, { state: "failed", error: event.registration.failureReason || "The download failed" }));
});

self.addEventListener("backgroundfetchabort", (event) => {
  event.waitUntil(update(event.registration.id, { state: "failed", error: "Cancelled" }));
});

self.addEventListener("backgroundfetchclick", (event) => {
  event.waitUntil(self.clients.openWindow("/downloads"));
});

// The same IndexedDB the page uses (src/lib/offline/store.ts).
function database() {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open(DB_NAME, 1);
    open.onupgradeneeded = () => open.result.createObjectStore(STORE, { keyPath: "id" });
    open.onsuccess = () => resolve(open.result);
    open.onerror = () => reject(open.error);
  });
}

async function update(id, changes) {
  const db = await database();
  await new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, "readwrite");
    const store = tx.objectStore(STORE);
    const get = store.get(id);
    get.onsuccess = () => {
      if (get.result) store.put(Object.assign({}, get.result, changes));
    };
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
  new BroadcastChannel(CHANNEL).postMessage({ id });
}

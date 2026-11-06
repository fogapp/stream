/**
 * What's been saved to this browser for offline (PROPOSAL §11 Phase 6), in
 * IndexedDB so the service worker can mark a background download done with
 * the page closed. The bytes live in Cache Storage under /offline/<id>/….
 */

export const OFFLINE_STATES = ["downloading", "done", "failed"] as const;
export type OfflineState = (typeof OFFLINE_STATES)[number];

export interface OfflineItem {
  id: string;
  profileId: string | null;
  playable: { type: string; id: string };
  title: string;
  subtitle: string | null;
  backPath: string;
  size: number;
  mimeType: string;
  durationSeconds: number | null;
  optimized: boolean;
  expiresAt: string;
  createdAt: string;
  state: OfflineState;
  received: number;
  error: string | null;
  subtitles: { id: string; label: string; language: string | null; forced: boolean }[];
  hasPoster: boolean;
  /** Intro, recap and credits, for skip buttons with no network. */
  markers?: { kind: "intro" | "recap" | "credits"; start: number; end: number }[];
  skip?: { intro: boolean; recap: boolean; credits: boolean };
  /** The episode after this one: played next if it's downloaded too. */
  nextEpisodeId?: string | null;
  /** Where the viewer got to, and when that was last told to the server. */
  position: number;
  positionUpdatedAt: string | null;
  positionSyncedAt: string | null;
}

const DB_NAME = "stream-offline";
const STORE = "downloads";
const CHANNEL = "stream-downloads";

function database(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open(DB_NAME, 1);
    open.onupgradeneeded = () => open.result.createObjectStore(STORE, { keyPath: "id" });
    open.onsuccess = () => resolve(open.result);
    open.onerror = () => reject(open.error);
  });
}

async function run<T>(mode: IDBTransactionMode, body: (store: IDBObjectStore) => IDBRequest<T> | void): Promise<T | undefined> {
  const db = await database();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, mode);
    const request = body(tx.objectStore(STORE));
    tx.oncomplete = () => resolve(request ? request.result : undefined);
    tx.onerror = () => reject(tx.error);
  });
}

export async function listItems(): Promise<OfflineItem[]> {
  const items = (await run<OfflineItem[]>("readonly", (store) => store.getAll())) ?? [];
  return items.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
}

export async function getItem(id: string): Promise<OfflineItem | undefined> {
  return run<OfflineItem>("readonly", (store) => store.get(id));
}

export async function putItem(item: OfflineItem): Promise<void> {
  await run("readwrite", (store) => store.put(item));
  announce(item.id);
}

export async function updateItem(id: string, changes: Partial<OfflineItem>): Promise<void> {
  const item = await getItem(id);
  if (item) await putItem({ ...item, ...changes });
}

export async function deleteItem(id: string): Promise<void> {
  await run("readwrite", (store) => store.delete(id));
  announce(id);
}

/** Every tab and the service worker hear about every change. */
function announce(id: string) {
  const channel = new BroadcastChannel(CHANNEL);
  channel.postMessage({ id });
  channel.close();
}

export function onItemsChanged(listener: () => void): () => void {
  const channel = new BroadcastChannel(CHANNEL);
  channel.onmessage = listener;
  return () => channel.close();
}

const PROFILE_KEY = "stream_profile_id";

/** The profile last seen online: offline, its downloads are the ones shown. */
export function rememberProfile(id: string | null) {
  try {
    if (id) localStorage.setItem(PROFILE_KEY, id);
  } catch {
    // Storage unavailable: offline shows every download on this device.
  }
}

export function lastProfileId(): string | null {
  try {
    return localStorage.getItem(PROFILE_KEY);
  } catch {
    return null;
  }
}

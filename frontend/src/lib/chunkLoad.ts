/**
 * A lazy route chunk that a deploy removed while this tab was open. The
 * server answers a missing .js with a script that reloads, but a missing
 * stylesheet (Vite preloads a chunk's CSS) still fails the import — one
 * reload picks up the new build.
 */
export const CHUNK_RELOAD_FLAG = "stream-chunk-reload-attempted";

export function isChunkLoadError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  return /failed to fetch dynamically imported module|error loading dynamically imported module|importing a module script failed|failed to load module script|unable to preload css/i.test(
    error.message,
  );
}

/** Reloads once per tab session; false when that already happened. */
export function reloadForChunkError(): boolean {
  try {
    if (sessionStorage.getItem(CHUNK_RELOAD_FLAG)) return false;
    sessionStorage.setItem(CHUNK_RELOAD_FLAG, "1");
  } catch {
    return false;
  }
  window.location.reload();
  return true;
}

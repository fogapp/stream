/** Set by the 10-foot layout, cleared by the desktop's (PROPOSAL §7.4). */
export const TV_KEY = "stream_tv";

/** A title's TV page for a desktop path, when coming back from the player. */
export function tvPath(path: string): string {
  const match = path.match(/^\/(movie|show)\/([^/?]+)/);
  return match ? `/tv/${match[1]}/${match[2]}` : "/tv";
}

/** A library's TV page for a desktop path, when coming back from a stream. */
export function tvLibraryPath(path: string): string {
  return path.startsWith("/library/") ? `/tv${path}` : "/tv";
}

/** Whether the player was reached from the TV layout, so Back returns there. */
export function fromTv(): boolean {
  try {
    return sessionStorage.getItem(TV_KEY) === "1";
  } catch {
    return false;
  }
}

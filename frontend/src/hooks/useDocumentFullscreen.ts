import { useSyncExternalStore } from "react";

function subscribe(onChange: () => void) {
  document.addEventListener("fullscreenchange", onChange);
  return () => document.removeEventListener("fullscreenchange", onChange);
}

/** Whether anything on the page is in the browser's full screen now. */
export function useDocumentFullscreen(): boolean {
  return useSyncExternalStore(subscribe, () => Boolean(document.fullscreenElement), () => false);
}

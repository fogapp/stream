import { useCallback, useEffect, useState } from "react";

const KEY = "stream_sidebar_collapsed";

function initial(): boolean {
  try {
    return localStorage.getItem(KEY) === "1";
  } catch {
    return false;
  }
}

/**
 * Whether this browser keeps the desktop sidebar folded down to its icons.
 * A per-screen preference, like the theme — a laptop and a big monitor
 * want different answers — so it lives in the browser, not the profile.
 */
export function useSidebarCollapsed() {
  const [collapsed, setCollapsed] = useState(initial);

  useEffect(() => {
    try {
      localStorage.setItem(KEY, collapsed ? "1" : "0");
    } catch {
      // A nicety.
    }
  }, [collapsed]);

  const toggle = useCallback(() => setCollapsed((current) => !current), []);

  return { collapsed, toggle };
}

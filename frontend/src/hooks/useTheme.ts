import { useCallback, useEffect, useState } from "react";

const THEMES = ["light", "dark"] as const;
export type Theme = (typeof THEMES)[number];

const THEME_KEY = "stream_theme";

/** Dark unless someone chose light: Stream is watched in dark rooms. */
function initialTheme(): Theme {
  const stored = localStorage.getItem(THEME_KEY);
  return stored === "light" ? "light" : "dark";
}

export function useTheme() {
  const [theme, setThemeState] = useState<Theme>(initialTheme);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem(THEME_KEY, theme);
  }, [theme]);

  const toggle = useCallback(() => {
    setThemeState((current) => (current === "dark" ? "light" : "dark"));
  }, []);

  return { theme, toggle, setTheme: setThemeState };
}

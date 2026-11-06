import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "node:path";

const apiTarget = process.env.API_TARGET ?? "http://localhost:3003";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: { alias: { "@": path.resolve(__dirname, "./src") } },
  // JASSUB finds its worker and WASM with new URL(..., import.meta.url);
  // pre-bundling would move the module away from the files it points at.
  optimizeDeps: { exclude: ["jassub"] },
  server: {
    port: 5177,
    // Playwright writes traces/screenshots into e2e/.artifacts mid-run;
    // letting the watcher see them turns every artifact into a full page
    // reload under test.
    watch: { ignored: ["**/e2e/.artifacts/**"] },
    proxy: {
      "/api": { target: apiTarget, changeOrigin: true },
      "/up": { target: apiTarget, changeOrigin: true },
      // The byte surfaces the browser fetches itself (PROPOSAL §3.3): signed
      // artwork URLs and stream-token media URLs live outside /api.
      "/artwork": { target: apiTarget, changeOrigin: true },
      "/media": { target: apiTarget, changeOrigin: true },
      // Sign in with fog: the OpenID callback builds its redirect URI from
      // the request's host, so this one keeps the dev server's.
      "/auth/oidc": { target: apiTarget },
    },
  },
  // Rails serves the built console from public/. emptyOutDir stays false so a
  // frontend build never wipes Rails' own static error pages.
  build: { outDir: "../public", emptyOutDir: false },
});

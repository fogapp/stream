import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./index.css";
import { App } from "./App";
import { prefersNativeHls, primeCapabilities } from "./lib/capabilities";
import { trackInputModality } from "./lib/inputModality";

trackInputModality();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);

// The player's heavier pieces, fetched once the app has painted and the
// browser is idle (docs/PERF_PROPOSAL.md › P7), so pressing Play never
// waits on downloading hls.js after the session answers. Only what this
// browser will use: Safari plays HLS itself.
const warm = () => {
  if (!prefersNativeHls()) void import("hls.js/light").catch(() => undefined);
  void import("jassub").catch(() => undefined);
  void import("libpgs").catch(() => undefined);
  // What this browser plays smoothly and as real HDR, asked once in the
  // background.
  void primeCapabilities().catch(() => undefined);
};
if (typeof window.requestIdleCallback === "function") window.requestIdleCallback(warm, { timeout: 5_000 });
else setTimeout(warm, 2_000);

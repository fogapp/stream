import { execFileSync } from "node:child_process";
import { rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { SESSION_FILE } from "./support/harness";
import { startTranscoder, stopTranscoder } from "./support/transcoder";

// Reset the fixture household once per run, before any spec opens a browser.
// The task is idempotent, so a run always starts from the same known shape —
// which is what lets specs assert on exact titles and counts.
//
// Then start a transcoder (PROPOSAL §3.2) beside the Rails server, since
// streamed playback needs one and it has no port for webServer to wait on.
// The function returned is Playwright's teardown.
export default function globalSetup() {
  const repoRoot = path.resolve(import.meta.dirname, "../..");
  const env = { ...process.env, DATABASE_PORT: process.env.DATABASE_PORT ?? "5437", E2E: "1" };
  execFileSync("bin/rails", ["e2e:seed"], { cwd: repoRoot, env, stdio: ["ignore", "ignore", "inherit"] });
  // The seed signed everyone out; each run signs in afresh (support/harness.ts).
  rmSync(SESSION_FILE, { force: true });

  writeFileSync(path.join(import.meta.dirname, ".artifacts-transcoder.log"), "");
  startTranscoder();
  return stopTranscoder;
}

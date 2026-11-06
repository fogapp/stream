import { spawn } from "node:child_process";
import { openSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";

// The transcoder the harness runs beside Rails (PROPOSAL §3.2). Its pid lives
// in a file so a spec can restart it — the way a deploy does — and the
// run's teardown stops whichever one is running by then.
const REPO_ROOT = path.resolve(import.meta.dirname, "../../..");
const PID_FILE = path.join(import.meta.dirname, "..", ".artifacts-transcoder.pid");
const LOG_FILE = path.join(import.meta.dirname, "..", ".artifacts-transcoder.log");

export function startTranscoder(): number {
  const env = { ...process.env, DATABASE_PORT: process.env.DATABASE_PORT ?? "5437", E2E: "1" };
  const log = openSync(LOG_FILE, "a");
  const child = spawn("bin/transcoder", [], { cwd: REPO_ROOT, env, stdio: ["ignore", log, log], detached: true });
  child.unref();
  if (!child.pid) throw new Error("bin/transcoder didn't start");
  writeFileSync(PID_FILE, String(child.pid));
  return child.pid;
}

export function stopTranscoder() {
  let pid: number;
  try {
    pid = Number(readFileSync(PID_FILE, "utf8"));
  } catch {
    return;
  }
  try {
    process.kill(-pid, "SIGTERM");
  } catch {
    // Already gone.
  }
}

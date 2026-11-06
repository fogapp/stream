import { spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";

/**
 * A live stream to relay (PROPOSAL §7.8): ffmpeg's test picture and tone as
 * live HLS (H.264 and AAC, a keyframe a second), served over HTTP from a
 * folder of its own — a web stream as Stream sees one. `stop` cuts it, as a
 * camera losing power would; `start` brings it back.
 */
export class LiveSource {
  readonly directory = mkdtempSync(path.join(tmpdir(), "stream-live-source-"));
  private ffmpeg: ChildProcess | null = null;
  private server: Server | null = null;
  port = 0;

  get url(): string {
    return `http://127.0.0.1:${this.port}/live.m3u8`;
  }

  async open(): Promise<void> {
    this.server = createServer((request, response) => {
      if (!this.ffmpeg) {
        response.writeHead(503).end();
        return;
      }
      const name = path.basename(request.url ?? "");
      try {
        const body = readFileSync(path.join(this.directory, name));
        response.writeHead(200, { "Content-Type": name.endsWith(".m3u8") ? "application/vnd.apple.mpegurl" : "video/mp2t" }).end(body);
      } catch {
        response.writeHead(404).end();
      }
    });
    await new Promise<void>((resolve) => this.server!.listen(0, "127.0.0.1", resolve));
    const address = this.server.address();
    this.port = typeof address === "object" && address ? address.port : 0;
    await this.start();
  }

  /** Producing, and the first segments written. */
  async start(): Promise<void> {
    this.ffmpeg = spawn(
      "ffmpeg",
      [
        "-hide_banner", "-loglevel", "error", "-re",
        "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-pix_fmt", "yuv420p", "-g", "25", "-keyint_min", "25",
        "-c:a", "aac", "-b:a", "96k",
        "-f", "hls", "-hls_time", "1", "-hls_list_size", "6", "-hls_flags", "delete_segments+omit_endlist",
        path.join(this.directory, "live.m3u8"),
      ],
      { stdio: "ignore" },
    );
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline) {
      try {
        if ((readFileSync(path.join(this.directory, "live.m3u8"), "utf8").match(/#EXTINF/g) ?? []).length >= 2) return;
      } catch {
        // Not yet.
      }
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    throw new Error("The live test source didn't start");
  }

  /** Cut: no more segments, and every request refused. */
  stop(): void {
    this.ffmpeg?.kill("SIGKILL");
    this.ffmpeg = null;
  }

  async close(): Promise<void> {
    this.stop();
    await new Promise<void>((resolve) => (this.server ? this.server.close(() => resolve()) : resolve()));
    rmSync(this.directory, { recursive: true, force: true });
  }
}

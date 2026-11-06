import { describe, expect, it, vi } from "vitest";
import { whenSubtitleReady } from "./subtitles";

const answer = (status: number, retryAfter?: string) =>
  new Response(status === 200 ? "WEBVTT\n" : "still", { status, headers: retryAfter ? { "Retry-After": retryAfter } : {} });

describe("whenSubtitleReady", () => {
  it("asks again while Stream is still taking the track out, as long as Retry-After says", async () => {
    const fetcher = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(answer(503, "10"))
      .mockResolvedValueOnce(answer(503, "60"))
      .mockResolvedValueOnce(answer(200));
    const sleep = vi.fn(async (_ms: number, _signal: AbortSignal) => undefined);
    await whenSubtitleReady("/media/s/t/subtitles/e3.sup", new AbortController().signal, { fetcher, sleep });
    expect(fetcher).toHaveBeenCalledTimes(3);
    // Retry-After, but never more than half a minute between asks.
    expect(sleep.mock.calls.map(([ms]) => ms)).toEqual([10_000, 30_000]);
  });

  it("ends the wait on any other answer: the renderer shows the track or its error", async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValueOnce(answer(422));
    await whenSubtitleReady("/x.vtt", new AbortController().signal, { fetcher, sleep: vi.fn() });
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it("gives up when it would wait past its patience", async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(answer(503, "10"));
    await expect(
      whenSubtitleReady("/x.vtt", new AbortController().signal, { fetcher, sleep: vi.fn(async () => undefined), patienceMs: 5_000 }),
    ).rejects.toThrow("still not ready");
  });
});

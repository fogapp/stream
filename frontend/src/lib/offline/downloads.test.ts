import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("./store", () => ({
  getItem: vi.fn(async () => ({ id: "d1" })),
  deleteItem: vi.fn(),
  lastProfileId: vi.fn(),
  listItems: vi.fn(async () => []),
  putItem: vi.fn(),
  updateItem: vi.fn(),
}));

import { fetchSubtitle } from "./downloads";
import { getItem } from "./store";

describe("fetchSubtitle", () => {
  const put = vi.fn();

  beforeEach(() => {
    put.mockReset();
    vi.stubGlobal("caches", { open: vi.fn(async () => ({ put })) });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("asks again after a 503 with Retry-After, then keeps the track", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce(new Response("still being taken out", { status: 503, headers: { "Retry-After": "10" } }))
      .mockResolvedValueOnce(new Response("WEBVTT", { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    const wait = vi.fn(async () => undefined);

    await expect(fetchSubtitle("d1", "s2", "/media/d/token/subtitles/s2.vtt", wait)).resolves.toBe(true);

    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(wait).toHaveBeenCalledWith(10_000);
    expect(put).toHaveBeenCalledWith("/offline/d1/subtitles/s2.vtt", expect.any(Response));
  });

  it("leaves out a track that can't be taken out", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("no", { status: 422 })));
    const wait = vi.fn(async () => undefined);

    await expect(fetchSubtitle("d1", "s2", "/media/d/token/subtitles/s2.vtt", wait)).resolves.toBe(false);
    expect(wait).not.toHaveBeenCalled();
    expect(put).not.toHaveBeenCalled();
  });

  it("stops once the download has been removed", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("WEBVTT", { status: 200 })));
    vi.mocked(getItem).mockResolvedValueOnce(undefined);

    await expect(fetchSubtitle("d1", "s2", "/media/d/token/subtitles/s2.vtt", vi.fn())).resolves.toBe(false);
    expect(put).not.toHaveBeenCalled();
  });
});

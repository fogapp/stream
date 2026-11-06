import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api, ApiError } from "@/api/client";
import { beaconProgress, postEvents, postProgress, readyInMs, stillPlayable } from "@/lib/playbackSession";

vi.mock("@/api/client", async (original) => ({
  ...(await original<typeof import("@/api/client")>()),
  api: { get: vi.fn(), post: vi.fn(), postForm: vi.fn(), delete: vi.fn() },
}));

const answer = (body: unknown, ok = true) => ({ ok, json: () => Promise.resolve(body) }) as Response;

describe("reports", () => {
  afterEach(() => void vi.unstubAllGlobals());

  it("posts events with keepalive, and shrugs off a failure", async () => {
    const fetcher = vi.fn(() => Promise.reject(new Error("offline")));
    vi.stubGlobal("fetch", fetcher);
    postEvents("/events", [{ kind: "stall", position: 3 }]);
    await Promise.resolve();
    expect(fetcher).toHaveBeenCalledWith("/events", expect.objectContaining({ method: "POST", keepalive: true, body: JSON.stringify({ events: [{ kind: "stall", position: 3 }] }) }));
  });

  it("hands back the server's answer to a progress report", async () => {
    vi.stubGlobal("fetch", vi.fn(() => Promise.resolve(answer({ completed: true }))));
    await expect(postProgress<{ completed: boolean }>("/progress", { position: 1, ended: false })).resolves.toEqual({ completed: true });
  });

  it("has no answer from a refusal or a failure", async () => {
    vi.stubGlobal("fetch", vi.fn(() => Promise.resolve(answer({}, false))));
    await expect(postProgress("/progress", { position: 1, ended: false })).resolves.toBeNull();
    vi.stubGlobal("fetch", vi.fn(() => Promise.reject(new Error("offline"))));
    await expect(postProgress("/progress", { position: 1, ended: false })).resolves.toBeNull();
  });

  it("beacons as text, since a beacon can't set JSON; says so when it can't", () => {
    const sendBeacon = vi.fn(() => true);
    vi.stubGlobal("navigator", { sendBeacon });
    expect(beaconProgress("/progress", { position: 1, ended: true })).toBe(true);
    const blob = (sendBeacon.mock.calls[0] as unknown as [string, Blob])[1];
    expect(blob.type).toBe("text/plain");
    vi.stubGlobal("navigator", {});
    expect(beaconProgress("/progress", { position: 1, ended: true })).toBe(false);
  });
});

describe("readyInMs", () => {
  it("is the server's wait, for a 409 that gave one", () => {
    expect(readyInMs(new ApiError(409, ["Getting it ready"], 3))).toBe(3_000);
  });

  it("is nothing for anything else", () => {
    expect(readyInMs(new ApiError(409, ["No"]))).toBeNull();
    expect(readyInMs(new ApiError(503, ["No"], 3))).toBeNull();
    expect(readyInMs(new Error("No"))).toBeNull();
  });
});

const get = vi.mocked(api.get);

describe("stillPlayable", () => {
  beforeEach(() => get.mockReset());

  it("asks the server about the title, and says what it says", async () => {
    get.mockResolvedValueOnce({ readable: true });
    await expect(stillPlayable("movie", "m1")).resolves.toBe(true);
    expect(get).toHaveBeenCalledWith("/playback_sessions/readable?playable_type=movie&playable_id=m1");

    get.mockResolvedValueOnce({ readable: false });
    await expect(stillPlayable("episode", "e1")).resolves.toBe(false);
  });

  it("is false for a purged title, and doesn't know when it couldn't ask", async () => {
    get.mockRejectedValueOnce(new ApiError(404, ["Not found"]));
    await expect(stillPlayable("movie", "gone")).resolves.toBe(false);

    get.mockRejectedValueOnce(new TypeError("Failed to fetch"));
    await expect(stillPlayable("movie", "m1")).resolves.toBeNull();
  });
});

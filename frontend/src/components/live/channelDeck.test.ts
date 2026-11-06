import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "@/api/client";
import { ChannelDeck } from "@/components/live/channelDeck";
import { attachSource } from "@/components/player/source";
import { createSession, postEvents, releaseSession } from "@/lib/playbackSession";
import type { PlaybackSessionInfo } from "@/types";

vi.mock("@/lib/playbackSession", () => ({ createSession: vi.fn(), releaseSession: vi.fn(), postEvents: vi.fn() }));
vi.mock("@/components/player/source", () => ({ attachSource: vi.fn(() => ({ detach: vi.fn(), setBufferLength: vi.fn() })) }));
vi.mock("@/components/player/audio", () => ({ playOrMute: vi.fn() }));
vi.mock("@/api/client", async (original) => ({
  ...(await original<typeof import("@/api/client")>()),
  api: { post: vi.fn(() => Promise.resolve()) },
}));

const create = vi.mocked(createSession);
const release = vi.mocked(releaseSession);

function session(id: string, live: Partial<NonNullable<PlaybackSessionInfo["live"]>> = {}) {
  return {
    id,
    events_url: "/events",
    source: { kind: "file", url: "/f" },
    resume_at: 0,
    method: "direct_play",
    live: {
      airing_id: `airing-${id}`,
      next_airing_id: null,
      media_start: 0,
      media_end: null,
      starts_at: new Date(Date.now() - 1000).toISOString(),
      ends_at: new Date(Date.now() + 60_000).toISOString(),
      server_now: new Date().toISOString(),
      ...live,
    },
  } as unknown as PlaybackSessionInfo;
}

const flush = async () => {
  await vi.advanceTimersByTimeAsync(0);
};

describe("ChannelDeck", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.clearAllMocks();
    create.mockImplementation((body) => Promise.resolve(session(String(body.station_id ?? "after"))));
  });
  afterEach(() => void vi.useRealTimers());

  it("tunes the channel on screen as a play and its neighbours on standby", async () => {
    const deck = new ChannelDeck("one");
    deck.setLineup("one", ["one", "two"]);
    await flush();
    expect(create).toHaveBeenCalledWith({ station_id: "one", standby: false });
    expect(create).toHaveBeenCalledWith({ station_id: "two", standby: true });
    expect(deck.views().map((view) => [view.stationId, view.state])).toEqual([
      ["one", "ready"],
      ["two", "ready"],
    ]);
  });

  it("tells whoever's listening when there's something new", async () => {
    const deck = new ChannelDeck("one");
    const listener = vi.fn();
    const unsubscribe = deck.subscribe(listener);
    const before = deck.getVersion();
    deck.setLineup("one", ["one"]);
    await flush();
    expect(deck.getVersion()).toBeGreaterThan(before);
    expect(listener).toHaveBeenCalled();
    listener.mockClear();
    unsubscribe();
    deck.retry();
    expect(listener).not.toHaveBeenCalled();
  });

  it("lets go of a channel off the line-up", async () => {
    const deck = new ChannelDeck("one");
    deck.setLineup("one", ["one", "two"]);
    await flush();
    deck.setLineup("one", ["one"]);
    expect(deck.views().map((view) => view.stationId)).toEqual(["one"]);
    expect(release).toHaveBeenCalledWith(expect.objectContaining({ id: "two" }));
  });

  it("drops an answer for a tune since overtaken", async () => {
    let answer: (value: PlaybackSessionInfo) => void = () => undefined;
    create.mockImplementationOnce(() => new Promise((resolve) => (answer = resolve)));
    const deck = new ChannelDeck("one");
    deck.setLineup("one", ["one"]);
    deck.retry();
    await flush();
    answer(session("stale"));
    await flush();
    expect(release).toHaveBeenCalledWith(expect.objectContaining({ id: "stale" }));
  });

  it("tries a failing channel on screen again, twice, then says so", async () => {
    create.mockImplementation(() => Promise.reject(new Error("down")));
    const deck = new ChannelDeck("one");
    deck.setLineup("one", ["one"]);
    await flush();
    expect(deck.views()[0]?.state).toBe("tuning");
    await vi.advanceTimersByTimeAsync(1_500);
    expect(create).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(5_000);
    expect(create).toHaveBeenCalledTimes(3);
    expect(deck.views()[0]?.state).toBe("failed");
  });

  it("doesn't retry what the server refused outright", async () => {
    create.mockImplementation(() => Promise.reject(new ApiError(422, ["No"])));
    const deck = new ChannelDeck("one");
    deck.setLineup("one", ["one"]);
    await flush();
    expect(deck.views()[0]?.state).toBe("failed");
    await vi.advanceTimersByTimeAsync(10_000);
    expect(create).toHaveBeenCalledOnce();
  });

  it("is ready for a line-up again after being let go: Strict Mode's rehearsal", async () => {
    const deck = new ChannelDeck("one");
    deck.setLineup("one", ["one"]);
    await flush();
    deck.dispose();
    expect(deck.views()).toEqual([]);
    expect(release).toHaveBeenCalledWith(expect.objectContaining({ id: "one" }));
    deck.setLineup("one", ["one"]);
    await flush();
    expect(deck.views()[0]?.state).toBe("ready");
    expect(create).toHaveBeenCalledTimes(2);
  });

  it("attaches a session to the element it's given, and hands back one ref callback per element", async () => {
    const deck = new ChannelDeck("one");
    deck.setLineup("one", ["one"]);
    const video = document.createElement("video");
    const bind = deck.bind("one");
    expect(deck.bind("one")).toBe(bind);
    bind(video);
    await flush();
    expect(attachSource).toHaveBeenCalledOnce();
    expect(deck.elementOf("one")).toBe(video);
  });

  it("says how long a change took, at its first frame", async () => {
    const deck = new ChannelDeck("one");
    deck.setLineup("one", ["one", "two"]);
    const video = document.createElement("video");
    deck.bind("two")(video);
    await flush();
    deck.setLineup("two", ["one", "two"]);
    deck.timeSwitch("two");
    video.dispatchEvent(new Event("playing"));
    expect(postEvents).toHaveBeenCalledWith("/events", [expect.objectContaining({ kind: "tune" })]);
    expect(video.dataset.tunedMs).toBeDefined();
  });
});

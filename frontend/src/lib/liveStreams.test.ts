import { describe, expect, it } from "vitest";
import { describeTracks, kindOfLink } from "@/lib/liveStreams";

describe("describeTracks", () => {
  it("says the picture first, then each sound", () => {
    expect(
      describeTracks([
        { kind: "audio", codec: "aac", width: null, height: null, frame_rate: null, channels: 1 },
        { kind: "audio", codec: "pcm_mulaw", width: null, height: null, frame_rate: null, channels: 2 },
        { kind: "video", codec: "h264", width: 3840, height: 2160, frame_rate: 24, channels: null },
      ]),
    ).toBe("H.264 3840×2160 24 fps · AAC mono · G.711 µ-law stereo");
  });
});

describe("kindOfLink", () => {
  it("knows a YouTube link, with or without its scheme", () => {
    expect(kindOfLink("https://www.youtube.com/watch?v=rFZHOHl-L8A")).toBe("youtube");
    expect(kindOfLink("youtu.be/rFZHOHl-L8A")).toBe("youtube");
    expect(kindOfLink(" https://m.youtube.com/@LofiGirl ")).toBe("youtube");
  });

  it("knows an MLB.tv game's link", () => {
    expect(kindOfLink("https://www.mlb.com/tv/g745652/vafbc56d6-7ad9-476d-98bb-04a247761609#game=745652")).toBe("mlb");
    expect(kindOfLink("mlb.com/tv/g745652")).toBe("mlb");
  });

  it("leaves other addresses alone, even ones that mention YouTube or MLB", () => {
    expect(kindOfLink("rtsps://192.168.1.1:7441/token")).toBeNull();
    expect(kindOfLink("https://example.com/youtube.com/live.m3u8")).toBeNull();
    expect(kindOfLink("https://notyoutube.com/live")).toBeNull();
    expect(kindOfLink("https://mlb.com.example.com/tv/g745652")).toBeNull();
  });
});

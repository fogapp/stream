import { afterEach, describe, expect, it, vi } from "vitest";

// What the browser says, per path: a
// file opened directly answers canPlayType; hls.js's stream answers
// MediaSource. They differ — Chrome opens HEVC files its MediaSource won't
// take on some machines.
describe("capabilityProfile", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.resetModules();
    vi.restoreAllMocks();
  });

  async function profileFor(file: (type: string) => boolean, streamed: (type: string) => boolean) {
    vi.stubGlobal("MediaSource", { isTypeSupported: streamed });
    vi.spyOn(HTMLMediaElement.prototype, "canPlayType").mockImplementation((type: string) => (file(type) ? "probably" : ""));
    const { capabilityProfile } = await import("@/lib/capabilities");
    return capabilityProfile();
  }

  it("answers for a file and for a stream separately, and finds each codec's highest level", async () => {
    const profile = await profileFor(
      (type) => /avc1|mp4a|hvc1\.1\.6\.L1(2|5)\d\.|^video\/mp4$/.test(type),
      (type) => /avc1\.6400(28|29|2a|32|33)|mp4a/.test(type),
    );
    expect(profile.hls).toBe("mse");
    expect(profile.video).toEqual(expect.arrayContaining(["h264", "hevc"]));
    expect(profile.stream_video).toContain("h264");
    expect(profile.stream_video).not.toContain("hevc");
    expect(profile.levels).toMatchObject({ h264: 52, hevc: 156 });
    expect(profile.max_audio_channels).toBeGreaterThanOrEqual(2);
  });
});

import { afterEach, describe, expect, it, vi } from "vitest";
import { failureMessage, hlsMediaFailure, leavePlayer, mediaErrorFailure, reportFallingBehind } from "@/components/player/failure";
import { toast } from "@/components/ui/Toast";

const error = (code: number, message = "said") => ({ code, message }) as MediaError;

describe("reportFallingBehind", () => {
  it("says so only for a file its storage can't keep up with", () => {
    const info = vi.spyOn(toast, "info").mockImplementation(() => undefined);
    reportFallingBehind({ falls_behind: false, title: "Heat" });
    expect(info).not.toHaveBeenCalled();
    reportFallingBehind({ falls_behind: true, title: "Heat" });
    expect(info).toHaveBeenCalledWith("Its storage can't keep up, so it will keep stopping to load.", { title: "Heat" });
    info.mockRestore();
  });
});

describe("mediaErrorFailure", () => {
  it("classes the element's errors the way the server falls back by", () => {
    expect(mediaErrorFailure(error(3, "PIPELINE_ERROR_DECODE"))).toEqual({
      failureClass: "decode",
      cause: "MediaError 3: PIPELINE_ERROR_DECODE",
    });
    expect(mediaErrorFailure(error(4))?.failureClass).toBe("unsupported");
    expect(mediaErrorFailure(error(2))?.failureClass).toBe("network");
  });

  it("lets an abort the viewer caused go", () => {
    expect(mediaErrorFailure(error(1))).toBeNull();
    expect(mediaErrorFailure(null)).toBeNull();
  });
});

describe("hlsMediaFailure", () => {
  it("takes a codec MediaSource refused for a stream it won't open, anything else for one it couldn't decode", () => {
    expect(hlsMediaFailure("bufferAddCodecError", "type unsupported")).toEqual({
      failureClass: "unsupported",
      cause: "bufferAddCodecError: type unsupported",
    });
    expect(hlsMediaFailure("bufferAppendError", undefined).failureClass).toBe("decode");
  });
});

describe("failureMessage", () => {
  it("says why in the viewer's words, not the browser's", () => {
    expect(failureMessage({ failureClass: "decode", cause: "MediaError 3: PIPELINE_ERROR_DECODE" })).toBe("This browser couldn't decode the video.");
    expect(failureMessage({ failureClass: "stalled", cause: "nothing to show after 30 s" })).toBe("The stream stopped arriving.");
  });
});

describe("leavePlayer", () => {
  afterEach(() => window.history.replaceState(null, ""));

  it("goes back where the play was pressed", () => {
    window.history.replaceState({ idx: 2 }, "");
    const navigate = vi.fn();
    leavePlayer(navigate, "movie", "m1");
    expect(navigate).toHaveBeenCalledWith(-1);
  });

  it("opened from a link, goes to the title's page instead of out of the app", () => {
    window.history.replaceState({ idx: 0 }, "");
    const navigate = vi.fn();
    leavePlayer(navigate, "movie", "m1");
    expect(navigate).toHaveBeenCalledWith("/movie/m1", { replace: true });
    leavePlayer(navigate, "episode", "e1");
    expect(navigate).toHaveBeenLastCalledWith("/", { replace: true });
  });
});

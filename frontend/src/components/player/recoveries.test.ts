import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { recoveryLog } from "@/components/player/recoveries";

describe("recoveryLog", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("counts what happened by what it was, and sends it a few seconds on", () => {
    const send = vi.fn();
    const log = recoveryLog(send);
    log.add("bufferSeekOverHole", 61.5);
    log.add("bufferSeekOverHole", 70.2);
    log.add("picture froze", 64);
    expect(send).not.toHaveBeenCalled();
    vi.advanceTimersByTime(5_000);
    expect(send).toHaveBeenCalledWith([
      { message: "bufferSeekOverHole", count: 2, position: 61.5 },
      { message: "picture froze", count: 1, position: 64 },
    ]);
    vi.advanceTimersByTime(60_000);
    expect(send).toHaveBeenCalledTimes(1);
  });

  it("keeps the first cause the browser gave", () => {
    const send = vi.fn();
    const log = recoveryLog(send);
    log.add("mediaSourceRequiresReset", 2528, "MediaError 3: PIPELINE_ERROR_DECODE");
    log.add("mediaSourceRequiresReset", 0, "MediaSource closed while media attached");
    log.add("bufferSeekOverHole", 12);
    log.flush();
    expect(send).toHaveBeenCalledWith([
      { message: "mediaSourceRequiresReset", cause: "MediaError 3: PIPELINE_ERROR_DECODE", count: 2, position: 2528 },
      { message: "bufferSeekOverHole", count: 1, position: 12 },
    ]);
  });

  it("sends what there is when told to, and nothing when there's nothing", () => {
    const send = vi.fn();
    const log = recoveryLog(send);
    log.flush();
    expect(send).not.toHaveBeenCalled();
    log.add("fragLoadTimeOut", 12);
    log.flush();
    expect(send).toHaveBeenCalledWith([{ message: "fragLoadTimeOut", count: 1, position: 12 }]);
    vi.advanceTimersByTime(10_000);
    expect(send).toHaveBeenCalledTimes(1);
  });
});

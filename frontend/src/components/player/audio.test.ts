import { describe, expect, it } from "vitest";
import { levellingGain, volumeScale } from "@/components/player/audio";

describe("levellingGain", () => {
  it("brings a quiet film up and a loud video down to -20 LUFS", () => {
    expect(levellingGain({ integrated: -26, true_peak: -10 })).toBeCloseTo(6);
    expect(levellingGain({ integrated: -12, true_peak: -1 })).toBeCloseTo(-8);
  });

  it("never pushes a peak past -1 dBTP, nor boosts more than 9 dB", () => {
    expect(levellingGain({ integrated: -26, true_peak: -3 })).toBeCloseTo(2);
    expect(levellingGain({ integrated: -40, true_peak: -30 })).toBeCloseTo(9);
  });

  it("leaves an unmeasured file alone", () => {
    expect(levellingGain(null)).toBe(0);
  });
});

describe("volumeScale", () => {
  it("can only turn a loud file down without Web Audio", () => {
    expect(volumeScale({ integrated: -14, true_peak: -1 }, true, false)).toBeCloseTo(0.5, 1);
    expect(volumeScale({ integrated: -30, true_peak: -10 }, true, false)).toBe(1);
    expect(volumeScale({ integrated: -14, true_peak: -1 }, true, true)).toBe(1);
    expect(volumeScale({ integrated: -14, true_peak: -1 }, false, false)).toBe(1);
  });
});

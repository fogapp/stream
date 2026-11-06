import { describe, expect, it } from "vitest";
import { keys } from "./queryKeys";

describe("queryKeys", () => {
  it("nests factories under `all` so prefix invalidation reaches them", () => {
    expect(keys.activity.list({}).slice(0, 1)).toEqual(keys.activity.all);
    expect(keys.notifications.unreadCount().slice(0, 1)).toEqual(keys.notifications.all);
    expect(keys.notifications.list(2).slice(0, 1)).toEqual(keys.notifications.all);
    expect(keys.about.detail().slice(0, 1)).toEqual(keys.about.all);
  });

  it("distinguishes activity filters", () => {
    expect(keys.activity.list({ severity: "error" })).not.toEqual(keys.activity.list({}));
  });
});

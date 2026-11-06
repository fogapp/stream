import { afterEach, describe, expect, it, vi } from "vitest";
import { api } from "./client";

function respond(body: string, status: number) {
  vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(body, { status })));
}

afterEach(() => vi.unstubAllGlobals());

describe("api error bodies", () => {
  it("surfaces a gateway's HTML error page as its status, not a parse crash", async () => {
    respond("<html>502 Bad Gateway</html>", 502);

    await expect(api.post("/libraries", { name: "x" })).rejects.toMatchObject({
      name: "ApiError",
      status: 502,
      errors: ["HTTP 502"],
    });
  });

  it("reports a JSON error envelope word for word", async () => {
    respond(JSON.stringify({ errors: ["That doesn't look like a URL"] }), 422);

    await expect(api.post("/libraries", { name: "x" })).rejects.toMatchObject({
      errors: ["That doesn't look like a URL"],
    });
  });

  it("names a non-JSON body on a 200 rather than pretending it parsed", async () => {
    respond("<html>totally a page</html>", 200);

    await expect(api.get("/about")).rejects.toMatchObject({
      errors: ["The server returned something that wasn't JSON"],
    });
  });

  // Without a timeout there is no failure state at all — the query stays
  // pending forever and the console sits there looking like it's thinking.
  it("gives up on a server that never answers, rather than waiting forever", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockRejectedValue(new DOMException("timed out", "TimeoutError")),
    );

    await expect(api.get("/about")).rejects.toMatchObject({
      name: "ApiError",
      status: 0,
      errors: ["The server didn't answer in time"],
    });
  });

  it("distinguishes an unreachable server from one that answered slowly", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new TypeError("Failed to fetch")));

    await expect(api.get("/about")).rejects.toMatchObject({
      errors: ["Couldn't reach the server"],
    });
  });
});

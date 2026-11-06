import type { ReactNode } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { api } from "@/api/client";
import { useConnectionSettings } from "@/hooks/useConnectionSettings";

type Settings = { configured: false } | { configured: true; url: string };

const resource = { settings: () => ["thing", "settings"], all: ["thing"] };

function wrapper() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

describe("useConnectionSettings", () => {
  afterEach(() => vi.restoreAllMocks());

  it("has what's stored once it's set up", async () => {
    vi.spyOn(api, "get").mockResolvedValue({ configured: true, url: "http://thing" });
    const { result } = renderHook(() => useConnectionSettings<Settings>("/thing", resource), { wrapper: wrapper() });
    await waitFor(() => expect(result.current.current?.url).toBe("http://thing"));
  });

  it("has nothing when it isn't, and says the load failed when that's why", async () => {
    vi.spyOn(api, "get").mockRejectedValue(new Error("down"));
    const { result } = renderHook(() => useConnectionSettings<Settings>("/thing", resource), { wrapper: wrapper() });
    await waitFor(() => expect(result.current.settings.isError).toBe(true));
    expect(result.current.current).toBeNull();
  });

  it("takes a save's answer without asking again", async () => {
    const get = vi.spyOn(api, "get").mockResolvedValue({ configured: false });
    const { result } = renderHook(() => useConnectionSettings<Settings>("/thing", resource), { wrapper: wrapper() });
    await waitFor(() => expect(result.current.settings.isSuccess).toBe(true));
    act(() => void result.current.saved({ configured: true, url: "http://new" }));
    await waitFor(() => expect(result.current.current?.url).toBe("http://new"));
    expect(get).toHaveBeenCalledOnce();
  });
});

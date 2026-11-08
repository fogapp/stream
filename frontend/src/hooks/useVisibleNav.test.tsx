import type { ReactNode } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { renderHook, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { api } from "@/api/client";
import { useVisibleNav } from "@/hooks/useVisibleNav";

vi.mock("@/hooks/useAuth", () => ({ useAuth: () => ({ user: { id: "u", role: "member" } }) }));
vi.mock("@/hooks/useProfile", () => ({ useProfile: () => ({ profile: { kind: "standard" } }) }));

function wrapper() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>;
}

describe("useVisibleNav", () => {
  afterEach(() => vi.restoreAllMocks());

  it("waits on the sports, then offers the ones the household has", async () => {
    vi.spyOn(api, "get").mockImplementation(async (path: string) => ({ available: path === "/baseball" }));
    const { result } = renderHook(() => useVisibleNav(), { wrapper: wrapper() });
    expect(result.current.pending).toBe(true);
    await waitFor(() => expect(result.current.pending).toBe(false));
    const keys = result.current.entries.map(({ key }) => key);
    expect(keys).toContain("baseball");
    expect(keys).not.toContain("basketball");
    expect(keys).not.toContain("stats");
  });
});

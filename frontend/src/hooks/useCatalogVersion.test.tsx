import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { renderHook, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { useCatalogVersion } from "./useCatalogVersion";

vi.mock("@/api/client", async (original) => ({
  ...(await original<typeof import("@/api/client")>()),
  api: { get: vi.fn(), post: vi.fn(), postForm: vi.fn(), delete: vi.fn() },
}));

describe("useCatalogVersion", () => {
  beforeEach(() => vi.mocked(api.get).mockReset());

  it("refreshes the catalog, search and Hook's marks when the version moves, not on first sight", async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const invalidate = vi.spyOn(queryClient, "invalidateQueries");
    vi.mocked(api.get).mockResolvedValue({ version: "41.1" });
    const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>;
    renderHook(() => useCatalogVersion(), { wrapper });

    await waitFor(() => expect(queryClient.getQueryData(keys.catalog.version())).toEqual({ version: "41.1" }));
    expect(invalidate).not.toHaveBeenCalled();

    vi.mocked(api.get).mockResolvedValue({ version: "41.1" });
    await queryClient.refetchQueries({ queryKey: keys.catalog.version() });
    expect(invalidate).not.toHaveBeenCalled();

    vi.mocked(api.get).mockResolvedValue({ version: "42.2" });
    await queryClient.refetchQueries({ queryKey: keys.catalog.version() });
    await waitFor(() => expect(invalidate).toHaveBeenCalledWith({ queryKey: keys.home.all }));
    expect(invalidate).toHaveBeenCalledWith({ queryKey: keys.hook.all });
    expect(invalidate).toHaveBeenCalledWith({ queryKey: keys.search.all });
  });
});

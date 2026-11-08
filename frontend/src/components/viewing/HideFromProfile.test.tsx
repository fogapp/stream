import type { ReactNode } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { api } from "@/api/client";
import { useHideFromProfile } from "@/components/viewing/HideFromProfile";
import { keys } from "@/lib/queryKeys";

vi.mock("@/hooks/useProfile", () => ({ useProfile: () => ({ profile: { id: "p1", name: "Sam", kind: "standard" } }) }));

describe("useHideFromProfile", () => {
  afterEach(() => vi.restoreAllMocks());

  it("refreshes what the title leaves — rows, search, the Grid, subscriptions — and nothing else", async () => {
    vi.spyOn(api, "put").mockResolvedValue(undefined as never);
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const affected = [
      keys.home.hubs(),
      keys.search.results("dune"),
      keys.live.guide("now", "4h"),
      keys.subscriptions.feed(),
      keys.movies.detail("m1"),
      keys.profiles.content("p1"),
    ];
    const untouched = [keys.settings.general(), keys.profiles.current(), keys.remote.thisDevice()];
    for (const queryKey of [...affected, ...untouched]) client.setQueryData(queryKey, {});
    const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>;
    const { result } = renderHook(() => useHideFromProfile({ kind: "movie", id: "m1", title: "Dune" }), { wrapper });

    act(() => result.current?.hide());

    await waitFor(() => expect(client.getQueryState(keys.search.results("dune"))?.isInvalidated).toBe(true));
    for (const queryKey of affected) expect(client.getQueryState(queryKey)?.isInvalidated, String(queryKey)).toBe(true);
    for (const queryKey of untouched) expect(client.getQueryState(queryKey)?.isInvalidated, String(queryKey)).toBe(false);
  });
});

import type { ReactNode } from "react";
import { MutationCache, QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { toast } from "@/components/ui/Toast";
import { useMenuAction } from "@/hooks/useMenuAction";

function setup() {
  const failed = vi.fn();
  const client = new QueryClient({ mutationCache: new MutationCache({ onError: failed }) });
  const invalidate = vi.spyOn(client, "invalidateQueries");
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>;
  const hook = renderHook(() => useMenuAction(), { wrapper });
  return { client, invalidate, failed, hook };
}

describe("useMenuAction", () => {
  afterEach(() => vi.restoreAllMocks());

  it("says it's done and refreshes the keys the change moves", async () => {
    const info = vi.spyOn(toast, "info");
    const { hook, invalidate } = setup();
    act(() => hook.result.current({ work: () => Promise.resolve(), done: "Subscribed", refresh: [["channels"], ["home"]] }));
    await waitFor(() => expect(info).toHaveBeenCalledWith("Subscribed"));
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["channels"] });
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["home"] });
  });

  it("hands a refresh function the client", async () => {
    const refresh = vi.fn();
    const { hook, client } = setup();
    act(() => hook.result.current({ work: () => Promise.resolve(), done: "Marked", refresh }));
    await waitFor(() => expect(refresh).toHaveBeenCalledWith(client));
  });

  it("still finishes once the menu that asked has gone", async () => {
    const info = vi.spyOn(toast, "info");
    let answer: (() => void) | null = null;
    const { hook } = setup();
    act(() => hook.result.current({ work: () => new Promise<void>((resolve) => (answer = resolve)), done: "Done" }));
    await waitFor(() => expect(answer).not.toBeNull());
    hook.unmount();
    answer!();
    await waitFor(() => expect(info).toHaveBeenCalledWith("Done"));
  });

  it("leaves a failure to the shared mutation toast, and says nothing of success", async () => {
    const info = vi.spyOn(toast, "info");
    const { hook, failed } = setup();
    act(() => hook.result.current({ work: () => Promise.reject(new Error("nope")), done: "Done" }));
    await waitFor(() => expect(failed).toHaveBeenCalled());
    expect(info).not.toHaveBeenCalled();
  });
});

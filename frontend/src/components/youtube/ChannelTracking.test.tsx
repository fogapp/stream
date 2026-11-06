import type { ReactNode } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { api } from "@/api/client";
import { ChannelTracking } from "@/components/youtube/ChannelTracking";
import { keys } from "@/lib/queryKeys";
import type { ChannelTracking as Tracking } from "@/types";

vi.mock("@/components/youtube/TrackingRulesForm", () => ({
  TrackingRulesForm: ({ rules, onChange }: { rules: { keep_last: number | null }; onChange: (rules: unknown) => void }) => (
    <input aria-label="Keep" value={rules.keep_last ?? ""} onChange={(event) => onChange({ ...rules, keep_last: Number(event.target.value) })} />
  ),
}));

const tracking = { tracked: true, keep_last: 5, last_polled_at: null, last_poll_error: null, recent: [], downloads: { done: 1, queued: 1, downloading: 0, failed: 0 } } as unknown as Tracking;

describe("ChannelTracking", () => {
  afterEach(() => vi.restoreAllMocks());

  it("keeps a half-edited form when a poll brings new counts", async () => {
    vi.spyOn(api, "get").mockResolvedValue(tracking);
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>;
    render(<ChannelTracking channelId="c" />, { wrapper });
    fireEvent.click(await screen.findByRole("button", { name: /Rules and downloads/ }));
    fireEvent.change(screen.getByLabelText("Keep"), { target: { value: "9" } });

    act(() => void client.setQueryData(keys.youtube.tracking("c"), { ...tracking, downloads: { ...tracking.downloads, done: 2 } }));

    expect(screen.getByLabelText("Keep")).toHaveValue("9");
  });
});

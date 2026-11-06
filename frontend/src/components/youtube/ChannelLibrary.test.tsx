import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter } from "react-router-dom";
import { api } from "@/api/client";
import { ChannelLibrary } from "@/components/youtube/ChannelLibrary";
import type { Library } from "@/types";

vi.mock("@/hooks/useAuth", () => ({ useAuth: () => ({ user: { role: "member" } }) }));
const get = vi.spyOn(api, "get");

const feedRequests = () => get.mock.calls.map(([path]) => path).filter((path) => path.startsWith("/videos"));

function open(entry: string) {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[entry]}>
        <ChannelLibrary library={{ id: "lib", name: "YouTube" } as Library} />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe("ChannelLibrary", () => {
  beforeEach(() => {
    get.mockReset();
    get.mockImplementation((path: string) =>
      Promise.resolve((path.startsWith("/channels") ? [{ id: "c", title: "Channel", unwatched_count: 0, video_count: 1 }] : []) as never),
    );
  });

  it("opens on what's unwatched, and All asks for everything", async () => {
    open("/library/lib");
    expect(await screen.findByRole("radio", { name: "Unwatched" })).toHaveAttribute("aria-checked", "true");
    await waitFor(() => expect(feedRequests().at(-1)).toContain("unwatched=true"));

    fireEvent.click(screen.getByRole("radio", { name: "All" }));
    await waitFor(() => expect(feedRequests().at(-1)).not.toContain("unwatched"));
  });

  it("keeps All when the URL asks for it", async () => {
    open("/library/lib?filter=all");
    expect(await screen.findByRole("radio", { name: "All" })).toHaveAttribute("aria-checked", "true");
  });
});

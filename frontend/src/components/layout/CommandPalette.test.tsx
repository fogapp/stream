import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "@/api/client";
import type { HookHit, HookShow } from "@/types";
import { CommandPalette } from "./CommandPalette";

vi.mock("@/api/client", async (original) => ({
  ...(await original<typeof import("@/api/client")>()),
  api: { get: vi.fn(), post: vi.fn(), postForm: vi.fn(), delete: vi.fn() },
}));
const who = vi.hoisted(() => ({ role: "member", kind: "standard" }));
vi.mock("@/hooks/useAuth", () => ({ useAuth: () => ({ user: { id: "u", role: who.role } }) }));
vi.mock("@/hooks/useProfile", () => ({ useProfile: () => ({ profile: { kind: who.kind } }) }));

const hit = (overrides: Partial<HookHit>): HookHit => ({
  kind: "movie", provider: "tmdb", external_id: "1", title: "Arrival", year: 2016, overview: "Linguist meets heptapods.",
  poster_url: null, network: null, in_stream_id: null, requested: false, hook_show_id: null, ...overrides,
});

const severance: HookShow = {
  hook_show_id: "0b7c6c1e-3f7e-4f6a-9a51-2d1f0c4e8a10", title: "Severance", year: 2022, poster_url: null, network: "Apple TV+",
  in_stream_id: null, following: null,
  seasons: [
    { number: 1, episodes: 9, aired: 9, in_stream: 9, requested: 0, next_air_date: null },
    { number: 2, episodes: 10, aired: 10, in_stream: 0, requested: 0, next_air_date: null },
  ],
};

function renderPalette() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <CommandPalette open onOpenChange={() => undefined} />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe("CommandPalette, looking further in Hook", () => {
  beforeEach(() => {
    vi.mocked(api.get).mockReset().mockImplementation(async (path: string) => {
      if (path === "/hook") return { available: true };
      if (path.startsWith("/hook/search?kind=movie")) {
        return [hit({ external_id: "329865" }), hit({ external_id: "2", title: "Arrival II", in_stream_id: "m2" })];
      }
      if (path.startsWith("/hook/search?kind=show")) return [hit({ kind: "show", external_id: "95396", title: "Severance" })];
      if (path.startsWith("/search")) {
        return { movies: [], shows: [], episodes: [], people: [], collections: [], channels: [], videos: [], said: [], clips: [] };
      }
      return [];
    });
    vi.mocked(api.post).mockReset().mockImplementation(async (path: string) => {
      if (path === "/hook/movies") return { status: "wanted", explain: null };
      if (path === "/hook/shows") return severance;
      return { created: 10, already: 0, show: { ...severance, following: "New episodes from today" } };
    });
  });

  it("searches Hook on ⇧↵ and requests a film with Enter", async () => {
    renderPalette();
    const input = screen.getByRole("combobox");
    fireEvent.change(input, { target: { value: "arrival" } });
    expect(await screen.findByText("Look for “arrival” in Hook")).toBeInTheDocument();

    fireEvent.keyDown(input, { key: "Enter", shiftKey: true });
    const films = await screen.findByRole("group", { name: "Movies" });
    expect(within(films).getByText("In Stream")).toBeInTheDocument();
    expect(screen.getByRole("combobox")).toHaveAccessibleName("Find a film or show for Hook to get");

    fireEvent.keyDown(input, { key: "Enter" });
    await waitFor(() => expect(api.post).toHaveBeenCalledWith("/hook/movies", { provider: "tmdb", external_id: "329865" }));
    expect(await within(films).findByText("Requested")).toBeInTheDocument();

    fireEvent.keyDown(input, { key: "Escape" });
    expect(await screen.findByText("Look for “arrival” in Hook")).toBeInTheDocument();
  });

  it("opens a show to choose the seasons Stream lacks, and follows it for what airs from today", async () => {
    renderPalette();
    const input = screen.getByRole("combobox");
    fireEvent.change(input, { target: { value: "severance" } });
    fireEvent.click(await screen.findByRole("button", { name: "Look for it in Hook" }));

    fireEvent.click(await screen.findByText("Severance"));
    const seasons = await screen.findByRole("group", { name: "Seasons to request" });
    expect(within(seasons).getByRole("button", { name: /Season 1/ })).toBeDisabled();
    fireEvent.click(within(seasons).getByRole("button", { name: /Season 2/ }));
    fireEvent.click(screen.getByLabelText("Follow the show, so new episodes come as they air"));
    expect(screen.getByLabelText("Only episodes from today on")).toBeChecked();

    fireEvent.click(screen.getByRole("button", { name: "Request Season 2 and follow" }));
    await waitFor(() =>
      expect(api.post).toHaveBeenCalledWith(`/hook/shows/${severance.hook_show_id}/want`, { season_numbers: [2], follow: "future" }),
    );
    expect(await screen.findByText("Hook is looking for 10 episodes and will keep the show coming.")).toBeInTheDocument();
    expect(screen.getByText(/Following — New episodes from today/)).toBeInTheDocument();
  });
});

describe("CommandPalette, when search fails", () => {
  it("says the search failed rather than that nothing matches, and retries", async () => {
    let fail = true;
    vi.mocked(api.get).mockReset().mockImplementation(async (path: string) => {
      if (path === "/hook") return { available: false };
      if (path.startsWith("/search")) {
        if (fail) throw new Error("Search is down");
        return { movies: [], shows: [], episodes: [], people: [], collections: [], channels: [], videos: [], said: [], clips: [] };
      }
      return [];
    });
    renderPalette();
    fireEvent.change(screen.getByRole("combobox"), { target: { value: "zzqx" } });
    expect(await screen.findByRole("alert")).toHaveTextContent("Search isn't answering right now.");
    expect(screen.queryByText("Nothing matches “zzqx”.")).not.toBeInTheDocument();

    fail = false;
    fireEvent.click(screen.getByRole("button", { name: "Try again" }));
    expect(await screen.findByText("Nothing matches “zzqx”.")).toBeInTheDocument();
  });
});

describe("CommandPalette, going somewhere", () => {
  beforeEach(() => {
    vi.mocked(api.get).mockReset().mockImplementation(async (path: string) => {
      if (path === "/hook") return { available: false };
      if (path === "/baseball") return { available: true };
      if (path === "/basketball") return { available: false };
      if (path === "/libraries") return [{ id: "l1", name: "Movies", kind: "movies" }];
      return [];
    });
  });
  afterEach(() => Object.assign(who, { role: "member", kind: "standard" }));

  const goTo = async () => {
    renderPalette();
    const group = await screen.findByRole("group", { name: "Go to" });
    await within(group).findByText("Baseball");
    return within(group).getAllByRole("option").map((option) => option.textContent);
  };

  it("offers the sidebar's destinations, in its order, after Home and the libraries", async () => {
    expect(await goTo()).toEqual([
      "Home", "Movies", "Grid", "Baseball", "Subscriptions", "Collections", "Playlists", "Needs match", "Activity", "Notifications", "Settings",
    ]);
  });

  it("offers an admin Stats and the Playback decisions", async () => {
    who.role = "admin";
    const shown = await goTo();
    expect(shown).toContain("Stats");
    expect(shown).toContain("Playback decisions");
  });

  it("keeps the running from a kid profile", async () => {
    Object.assign(who, { role: "admin", kind: "kid" });
    expect(await goTo()).toEqual(["Home", "Movies", "Grid", "Baseball", "Subscriptions", "Collections", "Playlists", "Notifications"]);
  });
});

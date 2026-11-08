import type { ReactNode } from "react";
import { focusManager, QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, render } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "@/api/client";
import { POLL_MS, RemoteListener } from "@/components/remote/RemoteListener";
import type { RemoteCommand } from "@/types";

const close = vi.fn();
vi.mock("@/hooks/usePlayback", () => ({ usePlaybackActions: () => ({ close }) }));
vi.mock("@/hooks/useProfile", () => ({ useProfile: () => ({ profile: { id: "p1" }, adopt: vi.fn() }) }));

let commandCalls = 0;
let nextCommands: RemoteCommand[] = [];

function mount(path: string) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>{children}</MemoryRouter>
    </QueryClientProvider>
  );
  return render(<RemoteListener />, { wrapper });
}

const tick = () => act(async () => void (await vi.advanceTimersByTimeAsync(POLL_MS)));

describe("RemoteListener", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    commandCalls = 0;
    nextCommands = [];
    close.mockClear();
    vi.spyOn(api, "get").mockImplementation(async (path: string) => {
      if (path === "/remote/this_device") return { remote_control: true } as never;
      commandCalls += 1;
      return nextCommands as never;
    });
    vi.spyOn(api, "patch").mockResolvedValue({} as never);
  });
  afterEach(() => {
    focusManager.setFocused(undefined);
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("carries out each command once, however often a poll answers it", async () => {
    nextCommands = [{ id: "c-stop-1", kind: "stop", payload: {} } as RemoteCommand];
    mount("/");
    await tick();
    await tick();
    expect(commandCalls).toBeGreaterThanOrEqual(2);
    expect(close).toHaveBeenCalledTimes(1);
  });

  it("stops asking from a hidden desktop tab", async () => {
    mount("/");
    await tick();
    const asked = commandCalls;
    expect(asked).toBeGreaterThan(0);
    act(() => focusManager.setFocused(false));
    await tick();
    await tick();
    expect(commandCalls).toBe(asked);
  });

  it("keeps asking from a TV's hidden tab", async () => {
    mount("/tv");
    await tick();
    const asked = commandCalls;
    act(() => focusManager.setFocused(false));
    await tick();
    await tick();
    expect(commandCalls).toBeGreaterThanOrEqual(asked + 2);
  });
});

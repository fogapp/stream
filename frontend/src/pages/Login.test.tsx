import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "@/api/client";
import { AuthProvider } from "@/hooks/useAuth";
import { Login } from "./Login";

vi.mock("@/api/client", async (original) => ({
  ...(await original<typeof import("@/api/client")>()),
  api: { get: vi.fn(), post: vi.fn(), postForm: vi.fn(), delete: vi.fn() },
}));

function renderLogin() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <AuthProvider>
        <MemoryRouter initialEntries={["/login"]}>
          <Login />
        </MemoryRouter>
      </AuthProvider>
    </QueryClientProvider>,
  );
}

describe("Login", () => {
  beforeEach(() => {
    vi.mocked(api.get).mockReset();
  });

  afterEach(() => {
    window.history.replaceState(null, "", "/");
  });

  it("offers only Stream's own sign-in when no provider is configured", async () => {
    vi.mocked(api.get).mockResolvedValue({ setup_required: false, signin: { enabled: false, fog_only: false } });
    renderLogin();

    expect(await screen.findByRole("button", { name: "Sign in" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Sign in with fog" })).not.toBeInTheDocument();
  });

  it("offers fog beside Stream's own sign-in while Stream is not yet fog-only", async () => {
    vi.mocked(api.get).mockResolvedValue({ setup_required: false, signin: { enabled: true, fog_only: false } });
    renderLogin();

    expect(await screen.findByRole("button", { name: "Sign in with fog" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Sign in" })).toBeInTheDocument();
  });

  // Once Stream has proven it runs on fog, fog is the only door: no
  // password form, no passkeys, no invite codes and no setup wizard — the
  // first person through fog is the admin.
  it("shows only fog once Stream is fog-only", async () => {
    vi.mocked(api.get).mockResolvedValue({ setup_required: false, signin: { enabled: true, fog_only: true } });
    renderLogin();

    expect(await screen.findByRole("button", { name: "Sign in with fog" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Sign in" })).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Password")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Have an invite code?" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Restore from backup" })).not.toBeInTheDocument();
  });

  it("says why a fog sign-in came back refused", async () => {
    window.history.replaceState(null, "", "/login#signin_error=access_denied");
    vi.mocked(api.get).mockResolvedValue({ setup_required: false, signin: { enabled: true, fog_only: true } });
    renderLogin();

    expect(await screen.findByRole("alert")).toHaveTextContent("fog didn't let you in");
  });
});

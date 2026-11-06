import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "@/api/client";
import { AuthProvider } from "@/hooks/useAuth";
import { SigninComplete } from "./SigninHandoff";

vi.mock("@/api/client", async (original) => ({
  ...(await original<typeof import("@/api/client")>()),
  api: { get: vi.fn(), post: vi.fn(), postForm: vi.fn(), delete: vi.fn() },
}));

function renderAt(hash: string) {
  window.history.replaceState(null, "", `/auth/complete${hash}`);
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return render(
    <QueryClientProvider client={client}>
      <AuthProvider>
        <MemoryRouter initialEntries={["/auth/complete"]}>
          <Routes>
            <Route path="/auth/complete" element={<SigninComplete />} />
            <Route path="/library/x" element={<p>library page</p>} />
            <Route path="/" element={<p>home page</p>} />
          </Routes>
        </MemoryRouter>
      </AuthProvider>
    </QueryClientProvider>,
  );
}

describe("SigninComplete", () => {
  beforeEach(() => {
    vi.mocked(api.post).mockReset();
  });

  it("trades the one-time code for a session and goes where the person was headed", async () => {
    vi.mocked(api.post).mockResolvedValue({
      token: "t",
      user: { id: "u", email: "k@fog.invalid", name: "Kim", role: "member" },
    });
    renderAt("#handoff=abc&return_to=%2Flibrary%2Fx");

    expect(await screen.findByText("library page")).toBeInTheDocument();
    expect(api.post).toHaveBeenCalledWith("/handoff", { handoff: "abc" });
    // The code is gone from the address bar once read.
    expect(window.location.hash).toBe("");
  });

  it("never follows a return path off this host", async () => {
    vi.mocked(api.post).mockResolvedValue({
      token: "t",
      user: { id: "u", email: "k@fog.invalid", name: "Kim", role: "member" },
    });
    renderAt("#handoff=abc&return_to=%2F%2Fevil.example%2F");

    expect(await screen.findByText("home page")).toBeInTheDocument();
  });

  it("says so when the code has expired", async () => {
    vi.mocked(api.post).mockRejectedValue(new Error("expired"));
    renderAt("#handoff=old");

    await waitFor(() =>
      expect(
        screen.getByRole("button", { name: "Back to sign-in" }),
      ).toBeInTheDocument(),
    );
  });
});

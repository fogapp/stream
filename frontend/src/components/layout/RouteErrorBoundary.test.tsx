import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";
import { RouteErrorBoundary } from "./RouteErrorBoundary";

function Bomb(): never {
  throw new Error("budget_used is undefined");
}

describe("RouteErrorBoundary", () => {
  it("contains a render crash to the page instead of white-screening", () => {
    const quiet = vi.spyOn(console, "error").mockImplementation(() => {});
    render(
      <MemoryRouter>
        <RouteErrorBoundary>
          <Bomb />
        </RouteErrorBoundary>
      </MemoryRouter>,
    );
    quiet.mockRestore();

    expect(screen.getByText("This page hit a rendering error.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Try again" })).toBeInTheDocument();
  });

  it("renders children when nothing is wrong", () => {
    render(
      <MemoryRouter>
        <RouteErrorBoundary>
          <p>All fine</p>
        </RouteErrorBoundary>
      </MemoryRouter>,
    );

    expect(screen.getByText("All fine")).toBeInTheDocument();
  });

  it("reloads once when a page's code vanished in a deploy, then offers a reload", () => {
    const quiet = vi.spyOn(console, "error").mockImplementation(() => {});
    const reload = vi.fn();
    vi.stubGlobal("location", { ...window.location, reload });
    sessionStorage.clear();
    function Stale(): never {
      throw new TypeError("Failed to fetch dynamically imported module: /assets/Library-OLD.js");
    }
    const tree = (
      <MemoryRouter>
        <RouteErrorBoundary>
          <Stale />
        </RouteErrorBoundary>
      </MemoryRouter>
    );

    const first = render(tree);
    expect(reload).toHaveBeenCalledTimes(1);
    first.unmount();
    render(tree);
    quiet.mockRestore();
    vi.unstubAllGlobals();

    expect(reload).toHaveBeenCalledTimes(1);
    expect(screen.getByText("Stream was updated.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Reload" })).toBeInTheDocument();
  });
});

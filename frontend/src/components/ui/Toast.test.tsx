import { act, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { Toasts, toast } from "./Toast";

describe("Toasts", () => {
  it("renders an error announcement when told", () => {
    render(<Toasts />);

    act(() => toast.error("Unsubscribe failed"));

    expect(screen.getByRole("alert")).toHaveTextContent("Unsubscribe failed");
  });

  it("renders nothing until something goes wrong", () => {
    const { container } = render(<Toasts />);
    expect(container).toBeEmptyDOMElement();
  });

  it("keeps a persistent one, with its title, until it's dismissed", () => {
    vi.useFakeTimers();
    try {
      render(<Toasts />);
      act(() => toast.error("The stream stopped arriving.", { title: "Couldn't play Heat", persistent: true }));
      act(() => vi.advanceTimersByTime(60_000));

      const alert = screen.getByRole("alert");
      expect(alert).toHaveTextContent("Couldn't play Heat");
      expect(alert).toHaveTextContent("The stream stopped arriving.");

      act(() => screen.getByRole("button", { name: "Dismiss" }).click());
      expect(screen.queryByRole("alert")).toBeNull();
    } finally {
      vi.useRealTimers();
    }
  });

  it("lets a passing one go, and shows the same news once", () => {
    vi.useFakeTimers();
    try {
      render(<Toasts />);
      act(() => toast.error("Couldn't save"));
      act(() => toast.error("Couldn't save"));
      expect(screen.getAllByRole("alert")).toHaveLength(1);

      act(() => vi.advanceTimersByTime(6_000));
      expect(screen.queryByRole("alert")).toBeNull();
    } finally {
      vi.useRealTimers();
    }
  });
});

import { describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen } from "@testing-library/react";
import { TableToolbar } from "./TableToolbar";

describe("TableToolbar", () => {
  it("searches once typing pauses, and clears every filter", () => {
    vi.useFakeTimers();
    const onSearch = vi.fn();
    const onClear = vi.fn();
    render(<TableToolbar search="" onSearch={onSearch} searchLabel="Search titles" active={2} onClear={onClear} summary="12 sessions" />);

    fireEvent.change(screen.getByRole("searchbox", { name: "Search titles" }), { target: { value: "heat" } });
    expect(onSearch).not.toHaveBeenCalled();
    act(() => vi.advanceTimersByTime(350));
    expect(onSearch).toHaveBeenCalledWith("heat");

    expect(screen.getByText("12 sessions")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Clear filters (2)" }));
    expect(onClear).toHaveBeenCalled();
    vi.useRealTimers();
  });
});

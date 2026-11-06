import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, within } from "@testing-library/react";
import { LayerList } from "@/components/live/LayerList";
import { EMPTY_BASE, newBlock } from "@/lib/stationDraft";

const blocks = [
  EMPTY_BASE,
  { ...newBlock("daypart", 0b0011111, 19 * 60, 23 * 60), name: "Primetime" },
  { ...newBlock("special", 127, 0, 1440), name: "Christmas", starts_on: "2026-12-25", ends_on: "2026-12-25" },
  { ...newBlock("daypart", 0b1100000, 7 * 60, 11 * 60), name: "Weekend mornings" },
];

describe("LayerList", () => {
  it("lists layers in the order they win: specials, appointments, dayparts, the mix", () => {
    render(<LayerList blocks={blocks} selected={0} onSelect={vi.fn()} onMove={vi.fn()} addControls={{}} />);
    const groups = screen.getAllByRole("list").map((list) => list.getAttribute("aria-label"));
    expect(groups).toEqual(["Specials", "Appointments", "Dayparts", "Mix"]);
    const dayparts = within(screen.getByRole("list", { name: "Dayparts" })).getAllByRole("listitem");
    expect(dayparts.map((item) => item.textContent)).toEqual(["PrimetimeWeekdays · 19:00–23:00", "Weekend morningsSat Sun · 07:00–11:00"]);
  });

  it("moves a layer within its kind with the arrow keys, and only within it", () => {
    const onMove = vi.fn();
    render(<LayerList blocks={blocks} selected={0} onSelect={vi.fn()} onMove={onMove} addControls={{}} />);
    const handle = screen.getByRole("button", { name: /^Reorder Weekend mornings/ });
    fireEvent.keyDown(handle, { key: "ArrowUp" });
    expect(onMove).toHaveBeenCalledWith(3, 1);
    fireEvent.keyDown(handle, { key: "ArrowDown" });
    expect(onMove).toHaveBeenCalledTimes(1);
    // A layer alone in its kind, and the mix, have nothing to reorder against.
    expect(screen.queryByRole("button", { name: /^Reorder Christmas/ })).toBeNull();
    expect(screen.queryByRole("button", { name: /^Reorder The channel's mix/ })).toBeNull();
  });
});

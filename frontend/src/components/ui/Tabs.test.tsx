import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { Tabs } from "./Tabs";

const TABS = [
  { key: "storage", label: "Storage" },
  { key: "integrations", label: "Integrations" },
  { key: "jobs", label: "Background jobs" },
] as const;

describe("Tabs", () => {
  it("marks the active tab and switches on click", () => {
    const onChange = vi.fn();
    render(<Tabs tabs={TABS} active="storage" onChange={onChange} label="Settings sections" />);

    expect(screen.getByRole("tab", { name: "Storage" })).toHaveAttribute("aria-selected", "true");
    fireEvent.click(screen.getByRole("tab", { name: "Background jobs" }));
    expect(onChange).toHaveBeenCalledWith("jobs");
  });

  it("moves with arrow keys and wraps at the ends", () => {
    const onChange = vi.fn();
    render(<Tabs tabs={TABS} active="storage" onChange={onChange} label="Settings sections" />);

    fireEvent.keyDown(screen.getByRole("tablist"), { key: "ArrowLeft" });
    expect(onChange).toHaveBeenCalledWith("jobs");
  });

  it("keeps only the active tab in the tab order", () => {
    render(<Tabs tabs={TABS} active="integrations" onChange={() => {}} label="Settings sections" />);

    expect(screen.getByRole("tab", { name: "Integrations" })).toHaveAttribute("tabindex", "0");
    expect(screen.getByRole("tab", { name: "Storage" })).toHaveAttribute("tabindex", "-1");
  });
});

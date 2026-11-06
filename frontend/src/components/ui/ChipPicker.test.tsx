import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { ChipPicker } from "@/components/ui/ChipPicker";

const options = [
  { value: "NBC", label: "NBC", hint: "12" },
  { value: "HBO", label: "HBO", hint: "8" },
  { value: "ABC", label: "ABC" },
];

describe("ChipPicker", () => {
  it("narrows as you type and adds the highlighted match on Enter", () => {
    const onChange = vi.fn();
    render(<ChipPicker label="Networks" options={options} selected={[]} onChange={onChange} />);
    const field = screen.getByRole("combobox", { name: "Networks" });
    fireEvent.change(field, { target: { value: "hb" } });
    expect(screen.getAllByRole("option").map((option) => option.textContent)).toEqual(["HBO8"]);
    fireEvent.keyDown(field, { key: "Enter" });
    expect(onChange).toHaveBeenCalledWith(["HBO"]);
  });

  it("shows the chosen as chips that can be removed", () => {
    const onChange = vi.fn();
    render(<ChipPicker label="Networks" options={options} selected={["NBC", "ABC"]} onChange={onChange} />);
    fireEvent.click(screen.getByRole("button", { name: "Remove NBC" }));
    expect(onChange).toHaveBeenCalledWith(["ABC"]);
  });

  it("takes what was typed when custom values are allowed", () => {
    const onChange = vi.fn();
    render(<ChipPicker label="Keywords" options={[]} selected={[]} onChange={onChange} allowCustom />);
    const field = screen.getByRole("combobox", { name: "Keywords" });
    fireEvent.change(field, { target: { value: "christmas" } });
    fireEvent.keyDown(field, { key: "Enter" });
    expect(onChange).toHaveBeenCalledWith(["christmas"]);
  });
});

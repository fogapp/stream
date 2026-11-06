import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { MutationForm } from "@/components/ui/MutationForm";
import { SecretInput } from "@/components/ui/SecretInput";

describe("MutationForm", () => {
  it("submits through the mutation, without leaving the page", () => {
    const mutate = vi.fn();
    render(
      <MutationForm mutation={{ mutate, isPending: false, errorMessage: null }} label="Save">
        <input aria-label="Name" />
      </MutationForm>,
    );
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    expect(mutate).toHaveBeenCalledOnce();
  });

  it("says why it failed, and holds while saving", () => {
    render(
      <MutationForm mutation={{ mutate: vi.fn(), isPending: true, errorMessage: "No." }} label="Save">
        <span />
      </MutationForm>,
    );
    expect(screen.getByRole("alert")).toHaveTextContent("No.");
    expect(screen.getByRole("button", { name: "Saving…" })).toBeDisabled();
  });
});

describe("SecretInput", () => {
  it("shows a saved one as saved, and otherwise what to enter", () => {
    const { rerender } = render(<SecretInput label="Key" value="" onChange={vi.fn()} saved={false} placeholder="From the site" />);
    expect(screen.getByLabelText("Key")).toHaveAttribute("placeholder", "From the site");
    expect(screen.getByLabelText("Key")).toHaveAttribute("type", "password");
    rerender(<SecretInput label="Key" value="" onChange={vi.fn()} saved placeholder="From the site" />);
    expect(screen.getByLabelText("Key")).toHaveAttribute("placeholder", "Saved — enter a new one to replace it");
  });
});

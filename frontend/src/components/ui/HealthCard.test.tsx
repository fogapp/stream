import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { HealthCard } from "./HealthCard";

describe("HealthCard", () => {
  it("is one link to where its number comes from, saying what to do", () => {
    render(
      <MemoryRouter>
        <HealthCard
          title="Failed plays"
          verdict="Do something"
          tone="danger"
          metric="2"
          detail="This week 2 conversions failed."
          action="See which ones, and why."
          to="/playback?tab=sessions&outcomes=failed"
        />
      </MemoryRouter>,
    );
    const link = screen.getByRole("link");
    expect(link).toHaveAttribute("href", "/playback?tab=sessions&outcomes=failed");
    expect(link).toHaveTextContent("Do something");
    expect(link).toHaveTextContent("See which ones, and why.");
  });
});

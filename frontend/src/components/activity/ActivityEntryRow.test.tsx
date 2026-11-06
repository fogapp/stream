import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it } from "vitest";
import type { ActivityEntry } from "@/types";
import { ActivityEntryRow } from "./ActivityEntryRow";

function entry(overrides: Partial<ActivityEntry> = {}): ActivityEntry {
  return {
    id: "e1",
    source: "ingest.rss",
    event: "fetch.completed",
    severity: "info",
    summary: "Fetched 12 items",
    subject_type: null,
    subject_id: null,
    subject: null,
    payload: {},
    duration_ms: 842,
    trace_id: null,
    created_at: "2026-08-02T12:00:00Z",
    ...overrides,
  };
}

function renderRow(props: Parameters<typeof ActivityEntryRow>[0]) {
  return render(
    <MemoryRouter>
      <ActivityEntryRow {...props} />
    </MemoryRouter>,
  );
}

describe("ActivityEntryRow", () => {
  it("renders summary, severity, and the source · event · duration line", () => {
    renderRow({ entry: entry() });
    expect(screen.getByText("Fetched 12 items")).toBeInTheDocument();
    expect(screen.getByText("info")).toBeInTheDocument();
    expect(screen.getByText("ingest.rss · fetch.completed · 842ms")).toBeInTheDocument();
  });

  it("omits the duration when it is null", () => {
    renderRow({ entry: entry({ duration_ms: null }) });
    expect(screen.getByText("ingest.rss · fetch.completed")).toBeInTheDocument();
  });

  it("links the subject when the server named it", () => {
    renderRow({
      entry: entry({
        subject_type: "Source",
        subject_id: "s1",
        subject: { type: "Source", id: "s1", label: "Blog", path: "/sources/s1" },
      }),
    });
    expect(screen.getByRole("link", { name: /Blog/ })).toHaveAttribute("href", "/sources/s1");
  });

  it("keeps a deleted subject visible without a link", () => {
    renderRow({
      entry: entry({
        subject_type: "Source",
        subject_id: "s1",
        subject: { type: "Source", id: "s1", label: null, path: null },
      }),
    });
    expect(screen.queryByRole("link")).not.toBeInTheDocument();
    expect(screen.getByText(/Source \(deleted\)/)).toBeInTheDocument();
  });

  it("shows the payload as chips, folding nested values and skipping ids", () => {
    renderRow({
      entry: entry({
        payload: { enqueued: 12, skipped_backoff: 0, source_id: "abc", nested: { a: 1 } },
      }),
    });
    expect(screen.getByText("enqueued:")).toBeInTheDocument();
    expect(screen.getByText("12")).toBeInTheDocument();
    expect(screen.getByText('{"a":1}')).toBeInTheDocument();
    expect(screen.queryByText("source_id:")).not.toBeInTheDocument();
  });

  it("prints a relative time when asked", () => {
    renderRow({ entry: entry({ created_at: new Date(Date.now() - 5 * 60_000).toISOString() }), timeStyle: "relative" });
    expect(screen.getByText("5m ago")).toBeInTheDocument();
  });
});

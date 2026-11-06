import { useState } from "react";
import { fireEvent, render, screen, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { DataTable } from "./DataTable";
import type { Column, SortState } from "@/lib/dataTable";

interface Row {
  id: string;
  name: string;
  count: number;
}

const rows: Row[] = [
  { id: "a", name: "Alpha", count: 3 },
  { id: "b", name: "Bravo", count: 1 },
];

const columns: Column<Row>[] = [
  { key: "name", header: "Name", cell: (row) => row.name, sortValue: (row) => row.name },
  { key: "count", header: "Count", cell: (row) => row.count, sortValue: (row) => row.count },
  { key: "actions", header: "", srHeader: "Actions", cell: () => <button>Do it</button> },
];

function Harness({ onSelectedChange }: { onSelectedChange?: (ids: string[]) => void }) {
  const [sort, setSort] = useState<SortState>({ key: "name", direction: "asc" });
  const [selected, setSelected] = useState<string[]>([]);
  return (
    <DataTable
      caption="Rows"
      columns={columns}
      rows={rows}
      rowKey={(row) => row.id}
      sort={sort}
      onSortChange={setSort}
      selection={{
        selected,
        onChange: (ids) => {
          setSelected(ids);
          onSelectedChange?.(ids);
        },
        rowLabel: (row) => `Select ${row.name}`,
      }}
      detail={(row) => (row.id === "a" ? <p>Alpha details</p> : null)}
    />
  );
}

describe("DataTable", () => {
  it("marks the sorted column for assistive tech and flips it on click", () => {
    render(<Harness />);

    expect(screen.getByRole("columnheader", { name: /name/i })).toHaveAttribute(
      "aria-sort",
      "ascending",
    );

    fireEvent.click(screen.getByRole("button", { name: /name/i }));
    expect(screen.getByRole("columnheader", { name: /name/i })).toHaveAttribute(
      "aria-sort",
      "descending",
    );
  });

  it("gives an unsortable column an accessible name but no sort control", () => {
    render(<Harness />);
    const header = screen.getByRole("columnheader", { name: "Actions" });
    expect(header).toHaveAttribute("aria-sort", "none");
    expect(within(header).queryByRole("button")).toBeNull();
  });

  it("selects and clears every shown row from the header checkbox", () => {
    const onSelectedChange = vi.fn();
    render(<Harness onSelectedChange={onSelectedChange} />);

    const all = screen.getByRole("checkbox", { name: /select every row shown/i });
    fireEvent.click(all);
    expect(onSelectedChange).toHaveBeenLastCalledWith(["a", "b"]);

    fireEvent.click(all);
    expect(onSelectedChange).toHaveBeenLastCalledWith([]);
  });

  it("shows the header checkbox as indeterminate when only some rows are ticked", () => {
    render(<Harness />);

    fireEvent.click(screen.getByRole("checkbox", { name: "Select Alpha" }));

    const all = screen.getByRole("checkbox", { name: /select every row shown/i });
    expect((all as HTMLInputElement).indeterminate).toBe(true);
    expect((all as HTMLInputElement).checked).toBe(false);
  });

  it("renders one header row per group, in the order the sort introduces them", () => {
    const grouped: Row[] = [
      { id: "a", name: "Alpha", count: 3 },
      { id: "b", name: "Bravo", count: 1 },
      { id: "c", name: "Charlie", count: 2 },
    ];

    function GroupedHarness() {
      const [sort, setSort] = useState<SortState>({ key: "count", direction: "desc" });
      return (
        <DataTable
          caption="Rows"
          columns={columns}
          rows={grouped}
          rowKey={(row) => row.id}
          sort={sort}
          onSortChange={setSort}
          group={{
            // Alpha and Charlie share a group; Bravo stands alone.
            of: (row) => (row.id === "b" ? "solo" : "pair"),
            header: (key, rows) => `${key} (${rows.length})`,
          }}
        />
      );
    }

    render(<GroupedHarness />);

    // Sorted by count desc: Alpha(3) leads, so "pair" comes before "solo".
    const headers = screen.getAllByRole("rowheader");
    expect(headers.map((header) => header.textContent)).toEqual(["pair (2)", "solo (1)"]);

    const cells = screen.getAllByRole("cell", { name: /alpha|bravo|charlie/i });
    expect(cells.map((cell) => cell.textContent)).toEqual(["Alpha", "Charlie", "Bravo"]);
  });

  it("reveals a row's detail panel, and offers no control for a row without one", () => {
    render(<Harness />);

    expect(screen.queryByText("Alpha details")).toBeNull();
    // Only Alpha has a panel, so there is exactly one disclosure control.
    const disclosures = screen.getAllByRole("button", { name: "Details" });
    expect(disclosures).toHaveLength(1);

    fireEvent.click(disclosures[0]);
    expect(screen.getByText("Alpha details")).toBeInTheDocument();
    expect(disclosures[0]).toHaveAttribute("aria-expanded", "true");
  });
});

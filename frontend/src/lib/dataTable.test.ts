import { describe, expect, it } from "vitest";
import { groupRows, nextSort, sortRows, type Column } from "./dataTable";

interface Row {
  name: string;
  count: number;
  when: number | null;
}

const columns: Column<Row>[] = [
  { key: "name", header: "Name", cell: (row) => row.name, sortValue: (row) => row.name },
  { key: "count", header: "Count", cell: (row) => row.count, sortValue: (row) => row.count },
  { key: "when", header: "When", cell: (row) => row.when, sortValue: (row) => row.when },
  { key: "actions", header: "", cell: () => null },
];

const rows: Row[] = [
  { name: "alpha", count: 10, when: 300 },
  { name: "bravo", count: 2, when: null },
  { name: "charlie", count: 10, when: 100 },
];

const names = (result: Row[]) => result.map((row) => row.name);

describe("sortRows", () => {
  it("sorts strings in both directions", () => {
    expect(names(sortRows(rows, columns, { key: "name", direction: "asc" }))).toEqual([
      "alpha",
      "bravo",
      "charlie",
    ]);
    expect(names(sortRows(rows, columns, { key: "name", direction: "desc" }))).toEqual([
      "charlie",
      "bravo",
      "alpha",
    ]);
  });

  it("sorts numbers numerically rather than lexically", () => {
    expect(names(sortRows(rows, columns, { key: "count", direction: "asc" }))).toEqual([
      "bravo",
      "alpha",
      "charlie",
    ]);
  });

  it("keeps ties in the order they arrived, so the server's ordering breaks them", () => {
    // alpha and charlie both have count 10, and alpha came first.
    const ascending = sortRows(rows, columns, { key: "count", direction: "asc" });
    expect(names(ascending).slice(1)).toEqual(["alpha", "charlie"]);
    const descending = sortRows(rows, columns, { key: "count", direction: "desc" });
    expect(names(descending).slice(0, 2)).toEqual(["alpha", "charlie"]);
  });

  it("sinks nulls to the bottom whichever way the column points", () => {
    expect(names(sortRows(rows, columns, { key: "when", direction: "asc" }))).toEqual([
      "charlie",
      "alpha",
      "bravo",
    ]);
    expect(names(sortRows(rows, columns, { key: "when", direction: "desc" }))).toEqual([
      "alpha",
      "charlie",
      "bravo",
    ]);
  });

  it("leaves rows alone for a column with no sortValue, or an unknown key", () => {
    expect(names(sortRows(rows, columns, { key: "actions", direction: "asc" }))).toEqual(names(rows));
    expect(names(sortRows(rows, columns, { key: "nope", direction: "asc" }))).toEqual(names(rows));
  });

  it("does not mutate the rows it was given", () => {
    const original = [...rows];
    sortRows(rows, columns, { key: "name", direction: "desc" });
    expect(rows).toEqual(original);
  });
});

describe("groupRows", () => {
  it("orders groups by first appearance and keeps each group's row order", () => {
    const grouped = groupRows(
      [
        { name: "alpha", count: 1, when: null },
        { name: "bravo", count: 2, when: null },
        { name: "alpha", count: 3, when: null },
      ],
      (row) => row.name,
    );
    expect(grouped.map((group) => group.key)).toEqual(["alpha", "bravo"]);
    expect(grouped[0].rows.map((row) => row.count)).toEqual([1, 3]);
  });

  it("returns no groups for no rows", () => {
    expect(groupRows([], () => "x")).toEqual([]);
  });
});

describe("nextSort", () => {
  it("starts a new column ascending", () => {
    expect(nextSort({ key: "name", direction: "desc" }, "count")).toEqual({
      key: "count",
      direction: "asc",
    });
  });

  it("flips the column already sorted", () => {
    expect(nextSort({ key: "name", direction: "asc" }, "name")).toEqual({
      key: "name",
      direction: "desc",
    });
    expect(nextSort({ key: "name", direction: "desc" }, "name")).toEqual({
      key: "name",
      direction: "asc",
    });
  });
});

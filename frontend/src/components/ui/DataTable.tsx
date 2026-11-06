import { Fragment, useMemo, useState, type ReactNode } from "react";
import { ArrowDown, ArrowUp, ChevronsUpDown } from "lucide-react";
import { BREAKPOINTS, useMediaQuery } from "@/hooks/useMediaQuery";
import { cn } from "@/lib/cn";
import { Checkbox } from "./Checkbox";
import { DisclosureButton } from "./DisclosureButton";
import {
  groupRows,
  nextSort,
  sortRows,
  type Column,
  type SortDirection,
  type SortState,
} from "@/lib/dataTable";

interface Grouping<Row> {
  /** Rows sharing a key sit together under one header row. Groups appear in
   *  the order the sorted rows introduce them, so the active sort orders the
   *  groups too. */
  of: (row: Row) => string;
  /** Content of the group's header row, spanning every column. */
  header: (key: string, rows: readonly Row[]) => ReactNode;
}

interface Selection<Row> {
  /** Ids of the rows currently ticked. Scope this to the rows you pass in —
   *  a bulk action must never reach a row the filters are hiding. */
  selected: string[];
  onChange: (ids: string[]) => void;
  /** Accessible label for one row's checkbox. */
  rowLabel: (row: Row) => string;
  /** Accessible label for the select-all box. */
  allLabel?: string;
}

interface DataTableProps<Row> {
  columns: Column<Row>[];
  rows: readonly Row[];
  rowKey: (row: Row) => string;
  sort: SortState;
  onSortChange: (sort: SortState) => void;
  /** Omit entirely for a flat, ungrouped table. */
  group?: Grouping<Row>;
  /** Omit entirely for a table with nothing to select. */
  selection?: Selection<Row>;
  /** Extra classes for a row that should read differently — dimmed, flagged. */
  rowClassName?: (row: Row) => string | undefined;
  /** Panel behind each row's disclosure control. Return null for a row with
   *  nothing more to say and it simply gets no control. */
  detail?: (row: Row) => ReactNode;
  /** Screen-reader description of what the table holds. */
  caption: string;
  /**
   * Fit the viewport instead of scrolling sideways. Columns then take the
   * widths their `className` asks for and the rest goes to whatever asked for
   * none, so every fluid table needs one column that truncates. Use it where
   * a row is a summary a person scans (the items timeline); leave it off where
   * a row is a record whose columns each need their full width.
   */
  fluid?: boolean;
  /** The rows already arrive in `sort` order — the caller sorted them, say by
   *  a column it isn't showing — so they are not sorted again here. */
  presorted?: boolean;
  /** A row as a card. With `cardBelow`, the rows render as these cards on
   *  screens narrower than that breakpoint, and as the table from it up — a
   *  record's columns have nowhere to go on a phone but sideways. Selection
   *  and grouping carry over; `detail` is table-only. */
  card?: (row: Row) => ReactNode;
  cardBelow?: keyof typeof BREAKPOINTS;
}

/**
 * A sortable table. Deliberately not a table *library*: sorting, selection and
 * row disclosure are the three things the console actually needs, and each is a
 * few lines here against a dependency that would arrive with its own opinions
 * about styling — which the cardinal color rule doesn't leave room for.
 */
export function DataTable<Row>({
  columns,
  rows,
  rowKey,
  sort,
  onSortChange,
  group,
  selection,
  detail,
  caption,
  rowClassName,
  fluid = false,
  presorted = false,
  card,
  cardBelow = "lg",
}: DataTableProps<Row>) {
  const [expanded, setExpanded] = useState<string[]>([]);
  const wide = useMediaQuery(BREAKPOINTS[cardBelow]);

  // Memoized: the items table renders every loaded page of an infinite
  // query, and re-sorting O(n log n) on every checkbox tick or engagement
  // re-render grew with scroll depth.
  const sorted = useMemo(() => (presorted ? rows : sortRows(rows, columns, sort)), [presorted, rows, columns, sort]);
  const groups = useMemo(
    () => (group ? groupRows(sorted, group.of) : [{ key: "", rows: sorted }]),
    [group, sorted],
  );
  const selectedIds = new Set(selection?.selected ?? []);
  const allSelected = sorted.length > 0 && sorted.every((row) => selectedIds.has(rowKey(row)));
  const someSelected = !allSelected && sorted.some((row) => selectedIds.has(rowKey(row)));
  const columnCount = columns.length + (selection ? 1 : 0) + (detail ? 1 : 0);

  function toggleAll(checked: boolean) {
    if (!selection) return;
    const shown = sorted.map(rowKey);
    selection.onChange(
      checked
        ? [...new Set([...selection.selected, ...shown])]
        : selection.selected.filter((id) => !shown.includes(id)),
    );
  }

  function toggleRow(id: string) {
    if (!selection) return;
    selection.onChange(
      selectedIds.has(id)
        ? selection.selected.filter((each) => each !== id)
        : [...selection.selected, id],
    );
  }

  if (card && !wide) {
    return (
      <ul className="divide-y divide-border" aria-label={caption}>
        {selection ? (
          <li className="flex items-center gap-3 px-4 py-2 text-xs text-muted">
            <Checkbox
              aria-label={selection.allLabel ?? "Select every row shown"}
              checked={allSelected}
              indeterminate={someSelected}
              onChange={toggleAll}
            />
            <span>{sorted.length} shown</span>
          </li>
        ) : null}
        {groups.map((section) => (
          <Fragment key={section.key || "all"}>
            {group ? (
              <li className="bg-surface-raised/80 px-4 py-2 text-sm font-medium text-foreground">{group.header(section.key, section.rows)}</li>
            ) : null}
            {section.rows.map((row) => {
              const id = rowKey(row);
              const selected = selectedIds.has(id);
              return (
                <li key={id} className={cn("flex items-start gap-3 px-4 py-3", selected && "bg-primary/5", rowClassName?.(row))}>
                  {selection ? (
                    <Checkbox className="mt-1" aria-label={selection.rowLabel(row)} checked={selected} onChange={() => toggleRow(id)} />
                  ) : null}
                  <div className="min-w-0 flex-1">{card(row)}</div>
                </li>
              );
            })}
          </Fragment>
        ))}
      </ul>
    );
  }

  return (
    <div className={fluid ? undefined : "overflow-x-auto"}>
      <table
        className={cn(
          "w-full border-collapse text-left text-sm",
          fluid ? "table-fixed" : "min-w-4xl",
        )}
      >
        <caption className="sr-only">{caption}</caption>
        <thead>
          <tr className="border-b border-border bg-surface-raised">
            {selection ? (
              <th scope="col" className="w-10 px-3 py-2.5">
                <Checkbox
                  aria-label={selection.allLabel ?? "Select every row shown"}
                  checked={allSelected}
                  indeterminate={someSelected}
                  onChange={toggleAll}
                />
              </th>
            ) : null}
            {detail ? (
              <th scope="col" className="w-9 px-1 py-2.5">
                <span className="sr-only">Details</span>
              </th>
            ) : null}
            {columns.map((column) => {
              const active = sort.key === column.key;
              return (
                <th
                  key={column.key}
                  scope="col"
                  aria-sort={
                    active ? (sort.direction === "asc" ? "ascending" : "descending") : "none"
                  }
                  className={cn(
                    "px-3 py-2.5 text-xs font-medium uppercase tracking-wide text-muted",
                    column.className,
                  )}
                >
                  {column.srHeader ? <span className="sr-only">{column.srHeader}</span> : null}
                  {column.sortValue ? (
                    <button
                      type="button"
                      onClick={() => onSortChange(nextSort(sort, column.key))}
                      className={cn(
                        "inline-flex items-center gap-1 uppercase tracking-wide transition-colors hover:text-foreground",
                        active && "text-foreground",
                      )}
                    >
                      {column.header}
                      <SortIcon active={active} direction={sort.direction} />
                    </button>
                  ) : (
                    column.header
                  )}
                </th>
              );
            })}
          </tr>
        </thead>

        {groups.map((section) => (
          <tbody key={section.key || "all"}>
            {group ? (
              <tr className="border-b border-border bg-surface-raised/80">
                <th
                  scope="rowgroup"
                  colSpan={columnCount}
                  className="px-3 py-2 text-left text-sm font-medium text-foreground"
                >
                  {group.header(section.key, section.rows)}
                </th>
              </tr>
            ) : null}
            {section.rows.map((row) => {
              const id = rowKey(row);
              const panel = detail ? detail(row) : null;
              const open = expanded.includes(id);
              const selected = selectedIds.has(id);

              return (
                <Fragment key={id}>
                  <tr
                    className={cn(
                      "border-b border-border transition-colors",
                      selected ? "bg-primary/5" : "hover:bg-surface-raised/60",
                      rowClassName?.(row),
                    )}
                  >
                    {selection ? (
                      <td className="px-3 py-2.5 align-top">
                        <Checkbox
                          checked={selected}
                          aria-label={selection.rowLabel(row)}
                          onChange={() => toggleRow(id)}
                          className="mt-1"
                        />
                      </td>
                    ) : null}
                    {detail ? (
                      <td className="px-1 py-2.5 align-top">
                        {panel ? (
                          <DisclosureButton
                            open={open}
                            onToggle={() =>
                              setExpanded((current) =>
                                current.includes(id)
                                  ? current.filter((each) => each !== id)
                                  : [...current, id],
                              )
                            }
                          />
                        ) : null}
                      </td>
                    ) : null}
                    {columns.map((column) => (
                      <td
                        key={column.key}
                        className={cn("px-3 py-2.5 align-top text-foreground", column.className)}
                      >
                        {column.cell(row)}
                      </td>
                    ))}
                  </tr>

                  {open && panel ? (
                    <tr className="border-b border-border bg-surface-raised/50">
                      <td colSpan={columnCount} className="px-5 py-4">
                        {panel}
                      </td>
                    </tr>
                  ) : null}
                </Fragment>
              );
            })}
          </tbody>
        ))}
      </table>
    </div>
  );
}

function SortIcon({ active, direction }: { active: boolean; direction: SortDirection }) {
  if (!active) return <ChevronsUpDown className="h-3 w-3 opacity-40" aria-hidden />;
  return direction === "asc" ? (
    <ArrowUp className="h-3 w-3" aria-hidden />
  ) : (
    <ArrowDown className="h-3 w-3" aria-hidden />
  );
}

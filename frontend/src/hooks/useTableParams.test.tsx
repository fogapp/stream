import { describe, expect, it } from "vitest";
import { act, renderHook } from "@testing-library/react";
import type { ReactNode } from "react";
import { MemoryRouter, useLocation } from "react-router-dom";
import { useTableParams } from "./useTableParams";

const SORT = { key: "started_at", direction: "desc" } as const;
const FILTERS = ["q", "methods", "device_id"] as const;
const ARRAYS = ["methods"] as const;

function setup(url: string) {
  const wrapper = ({ children }: { children: ReactNode }) => <MemoryRouter initialEntries={[url]}>{children}</MemoryRouter>;
  return renderHook(
    () => ({ table: useTableParams({ filters: FILTERS, arrays: ARRAYS, defaultSort: SORT }), location: useLocation() }),
    { wrapper },
  );
}

describe("useTableParams", () => {
  it("reads filters, sort and page from the URL into the API's query", () => {
    const { result } = setup("/playback?tab=sessions&q=heat&methods=remux&methods=direct&sort=stalls&dir=asc&page=3");
    expect(result.current.table.query).toEqual({ q: "heat", methods: ["remux", "direct"], sort: "stalls", direction: "asc", page: 3 });
    expect(result.current.table.active).toBe(2);
  });

  it("goes back to the first page when a filter or the sort changes, and leaves the tab alone", () => {
    const { result } = setup("/playback?tab=sessions&page=3");
    act(() => result.current.table.set({ methods: ["remux"] }));
    expect(result.current.location.search).toBe("?tab=sessions&methods=remux");
    act(() => result.current.table.setPage(2));
    act(() => result.current.table.setSort({ key: "errors", direction: "desc" }));
    expect(result.current.location.search).toBe("?tab=sessions&methods=remux&sort=errors&dir=desc");
  });

  it("clears every filter but keeps the sort", () => {
    const { result } = setup("/playback?tab=sessions&q=heat&device_id=d1&sort=stalls&dir=asc");
    act(() => result.current.table.clear());
    expect(result.current.location.search).toBe("?tab=sessions&sort=stalls&dir=asc");
    expect(result.current.table.active).toBe(0);
  });
});

import type { KeyValue } from "@/components/ui/KeyValueChips";

/**
 * A record's scalar fields as key: value chips, in the record's own order.
 * Null and empty values are dropped. A nested value is dropped too, unless
 * `foldObjects` asks for it as a short run of JSON instead.
 */
export function scalarChips(
  record: object,
  { max = Number.POSITIVE_INFINITY, skip, foldObjects = false }: { max?: number; skip?: ReadonlySet<string>; foldObjects?: boolean } = {},
): KeyValue[] {
  const chips: KeyValue[] = [];
  for (const [key, value] of Object.entries(record)) {
    if (chips.length >= max) break;
    if (skip?.has(key) || value === null || value === undefined || value === "") continue;
    if (typeof value === "object") {
      if (foldObjects) chips.push({ key, value: JSON.stringify(value).slice(0, 60) });
      continue;
    }
    chips.push({ key, value: String(value) });
  }
  return chips;
}

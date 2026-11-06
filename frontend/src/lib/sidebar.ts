/**
 * Items in the profile's order. One it hasn't placed — a library added
 * since, or one it just brought back — keeps its default place, right after
 * the item it follows by default.
 */
export function arrange<T extends { key: string }>(items: T[], order: string[]): T[] {
  const byKey = new Map(items.map((item) => [item.key, item]));
  const result = [...new Set(order)].flatMap((key) => byKey.get(key) ?? []);
  items.forEach((item, index) => {
    if (result.includes(item)) return;
    const previous = index > 0 ? result.indexOf(items[index - 1]) : -1;
    result.splice(previous + 1, 0, item);
  });
  return result;
}

/** `shown` with `key` moved one place up (-1) or down (+1); the ends stay put. */
export function move(shown: string[], key: string, by: -1 | 1): string[] {
  const at = shown.indexOf(key);
  const to = at + by;
  if (at < 0 || to < 0 || to >= shown.length) return shown;
  const next = [...shown];
  [next[at], next[to]] = [next[to], next[at]];
  return next;
}

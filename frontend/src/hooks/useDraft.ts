import { useCallback, useState } from "react";

/** What the server has for a draft's fields: any may be missing, or null for "not set". */
export type DraftSource<T> = { [K in keyof T]?: T[K] | null } | null | undefined;

/**
 * A form's edits, layered over the server's values. A field reads as what
 * was typed into it, else what's stored (`current`), else its default — so a
 * form starts from the server's values and does not re-sync on refetch:
 * a field once edited keeps the edit until `reset`, which a save's success
 * calls once the stored values are the saved ones. Fields the server never
 * returns (a secret) are just defaults: they start empty and stay write-only.
 */
export function useDraft<T extends Record<string, unknown>>(current: DraftSource<T>, defaults: T) {
  const [edits, setEdits] = useState<Partial<T>>({});
  const value = <K extends keyof T>(key: K): T[K] => (key in edits ? (edits[key] as T[K]) : ((current?.[key] ?? defaults[key]) as T[K]));
  const set = useCallback(<K extends keyof T>(key: K, next: T[K]) => setEdits((all) => ({ ...all, [key]: next })), []);
  const reset = useCallback(() => setEdits({}), []);
  /** Every field as it reads now: the body a save sends. */
  const values = (): T => Object.fromEntries(Object.keys(defaults).map((key) => [key, value(key)])) as T;
  return { value, values, set, reset, dirty: Object.keys(edits).length > 0 };
}

import { useState } from "react";

/**
 * The files ticked in a table of them: `shown` is the ticked ones still on
 * this page, so an action never reaches a row the person can't see.
 */
export function useBulkSelection(rows: { media_file_id: string }[]) {
  const [selected, setSelected] = useState<string[]>([]);
  const shown = selected.filter((id) => rows.some((row) => row.media_file_id === id));
  return { shown, setSelected };
}

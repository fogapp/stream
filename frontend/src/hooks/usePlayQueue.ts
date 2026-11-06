import { useCallback, useState } from "react";
import type { NextItem } from "@/types";

const QUEUE_KEY = "stream_queue";

function storedQueue(): NextItem[] {
  try {
    const parsed = JSON.parse(sessionStorage.getItem(QUEUE_KEY) ?? "[]") as unknown;
    return Array.isArray(parsed) ? (parsed as NextItem[]) : [];
  } catch {
    return [];
  }
}

/** Play next (PROPOSAL §5.4): what plays after this, ahead of Up next, for as long as the tab lasts. */
export function usePlayQueue() {
  const [queue, setQueue] = useState<NextItem[]>(storedQueue);
  const keepQueue = useCallback((next: NextItem[]) => {
    setQueue(next);
    try {
      sessionStorage.setItem(QUEUE_KEY, JSON.stringify(next));
    } catch {
      // A nicety.
    }
  }, []);
  const enqueue = useCallback((item: NextItem) => keepQueue([...queue.filter((queued) => queued.id !== item.id), item]), [queue, keepQueue]);
  const dequeue = useCallback((id: string) => keepQueue(queue.filter((queued) => queued.id !== id)), [queue, keepQueue]);
  return { queue, keepQueue, enqueue, dequeue };
}

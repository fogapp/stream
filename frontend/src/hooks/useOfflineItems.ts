import { useEffect, useState } from "react";
import { onItemsChanged, type OfflineItem } from "@/lib/offline/store";
import { offlineSupported, visibleItems } from "@/lib/offline/downloads";

/** What's saved in this browser, kept current as downloads move along. */
export function useOfflineItems(): { items: OfflineItem[]; loaded: boolean } {
  const [items, setItems] = useState<OfflineItem[]>([]);
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    if (!offlineSupported()) {
      setLoaded(true);
      return;
    }
    let live = true;
    const load = () =>
      void visibleItems()
        .then((next) => {
          if (live) {
            setItems(next);
            setLoaded(true);
          }
        })
        .catch(() => live && setLoaded(true));
    load();
    const stop = onItemsChanged(load);
    return () => {
      live = false;
      stop();
    };
  }, []);
  return { items, loaded };
}

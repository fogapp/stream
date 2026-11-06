import { useEffect, useRef, useState } from "react";
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { ClipTile } from "@/components/viewing/ClipTile";
import type { ClipPlace } from "@/types";

/**
 * Where home videos were taken (PROPOSAL §5.4), on OpenStreetMap: a dot
 * per place, sized by how many, opening its latest few. Loaded only when
 * someone opens the map; the tiles come from openstreetmap.org.
 */
export default function PlacesMap({ places }: { places: ClipPlace[] }) {
  const container = useRef<HTMLDivElement>(null);
  const [selected, setSelected] = useState<ClipPlace | null>(null);

  useEffect(() => {
    const element = container.current;
    if (!element || places.length === 0) return;
    const map = L.map(element, { worldCopyJump: true });
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 18,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    }).addTo(map);
    const color = getComputedStyle(document.documentElement).getPropertyValue("--color-primary").trim() || "currentColor";
    const most = Math.max(...places.map((place) => place.count));
    const markers = places.map((place) =>
      L.circleMarker([place.latitude, place.longitude], {
        radius: 6 + 14 * Math.sqrt(place.count / most),
        color,
        fillColor: color,
        fillOpacity: 0.6,
        weight: 1,
      })
        .bindTooltip(`${[place.city, place.country].filter(Boolean).join(", ") || "Here"} · ${place.count}`)
        .on("click", () => setSelected(place))
        .addTo(map),
    );
    map.fitBounds(L.featureGroup(markers).getBounds().pad(0.2), { maxZoom: 13 });
    return () => {
      map.remove();
    };
  }, [places]);

  return (
    <div className="space-y-4">
      <div ref={container} className="h-[28rem] w-full overflow-hidden rounded-[var(--radius-card)] ring-1 ring-border" role="application" aria-label="Map of where home videos were taken" />
      {selected ? (
        <section aria-label={`Taken in ${selected.city ?? "this place"}`} className="space-y-2">
          <h2 className="text-sm font-medium text-foreground">
            {[selected.city, selected.country].filter(Boolean).join(", ") || "Here"} · {selected.count} {selected.count === 1 ? "video" : "videos"}
          </h2>
          <ul className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
            {selected.clips.map((clip) => (
              <li key={clip.id}>
                <ClipTile clip={clip} showDate />
              </li>
            ))}
          </ul>
        </section>
      ) : (
        <p className="text-sm text-muted">Choose a place to see what was filmed there.</p>
      )}
    </div>
  );
}

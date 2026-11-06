import { useState, type ReactNode } from "react";
import { Baby, CalendarHeart, Clapperboard, History, Laugh, PencilRuler, Repeat, Tv } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { Select } from "@/components/ui/Select";
import type { PresetKind, StationOptions } from "@/types";

const HOLIDAYS = [
  { value: "christmas", label: "Christmas" },
  { value: "halloween", label: "Halloween" },
  { value: "thanksgiving", label: "Thanksgiving" },
] as const;

function Card({ icon, title, text, children }: { icon: ReactNode; title: string; text: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-3 rounded-[var(--radius-card)] border border-border bg-surface p-4">
      <div className="flex items-center gap-2">
        <span className="text-primary">{icon}</span>
        <h2 className="font-semibold">{title}</h2>
      </div>
      <p className="flex-1 text-sm text-muted">{text}</p>
      <div className="flex flex-wrap items-end gap-2">{children}</div>
    </div>
  );
}

/**
 * Where a new channel starts (PROPOSAL §7.7): a ready-made one, built from
 * what's in the library and opened in the editor to change as you like, or
 * a blank one.
 */
export function PresetPicker({ options, pending, onPick, onScratch }: { options: StationOptions; pending: boolean; onPick: (kind: PresetKind, value?: string) => void; onScratch: () => void }) {
  const [network, setNetwork] = useState(options.networks[0]?.value ?? "");
  const [decade, setDecade] = useState(String(options.decades[0]?.value ?? 1990));
  const [genre, setGenre] = useState("");
  const [show, setShow] = useState(options.shows[0]?.id ?? "");
  const [holiday, setHoliday] = useState<string>("christmas");

  return (
    <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
      <Card icon={<Tv className="h-5 w-5" aria-hidden />} title="A network" text="Its own shows, programmed the way it did: a broadcaster's primetime line-up, a premium channel's films and Sunday originals, cable's marathons.">
        {options.networks.length > 0 ? (
          <>
            <div className="min-w-40 flex-1">
              <Select label="Network" value={network} onChange={(event) => setNetwork(event.target.value)}>
                {options.networks.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.value} ({option.count})
                  </option>
                ))}
              </Select>
            </div>
            <Button disabled={pending || !network} onClick={() => onPick("network", network)}>
              Make it
            </Button>
          </>
        ) : (
          <p className="text-sm text-muted">No networks yet — they arrive with each show's details.</p>
        )}
      </Card>
      <Card icon={<Baby className="h-5 w-5" aria-hidden />} title="Kids" text="Cartoons and family shows rated for little ones, a family film after school, and Saturday morning cartoons.">
        <Button disabled={pending} onClick={() => onPick("kids")}>
          Make it
        </Button>
      </Card>
      <Card icon={<Laugh className="h-5 w-5" aria-hidden />} title="Sitcom reruns" text="Comedies all day, and each show in turn from 8pm, the way syndication did.">
        <Button disabled={pending} onClick={() => onPick("sitcoms")}>
          Make it
        </Button>
      </Card>
      <Card icon={<History className="h-5 w-5" aria-hidden />} title="A decade" text="What aired in the decade, in rotation, with a film from it every night at 8.">
        <div className="min-w-32 flex-1">
          <Select label="Decade" value={decade} onChange={(event) => setDecade(event.target.value)}>
            {(options.decades.length > 0 ? options.decades : [{ value: 1990, count: 0 }]).map((option) => (
              <option key={option.value} value={option.value}>
                {option.value}s{option.count ? ` (${option.count})` : ""}
              </option>
            ))}
          </Select>
        </div>
        <Button disabled={pending} onClick={() => onPick("decade", decade)}>
          Make it
        </Button>
      </Card>
      <Card icon={<Clapperboard className="h-5 w-5" aria-hidden />} title="A movie channel" text="Films back to back on the half hour, the best-rated in primetime — of one genre, or all.">
        <div className="min-w-40 flex-1">
          <Select label="Genre" value={genre} onChange={(event) => setGenre(event.target.value)}>
            <option value="">Every genre</option>
            {options.genres.map((option) => (
              <option key={option.value} value={option.value}>
                {option.value}
              </option>
            ))}
          </Select>
        </div>
        <Button disabled={pending} onClick={() => onPick("movies", genre)}>
          Make it
        </Button>
      </Card>
      <Card icon={<Repeat className="h-5 w-5" aria-hidden />} title="One show, all the time" text="Every episode in order from the first, around the clock.">
        <div className="min-w-40 flex-1">
          <Select label="Show" value={show} onChange={(event) => setShow(event.target.value)}>
            {options.shows.map((option) => (
              <option key={option.id} value={option.id}>
                {option.title}
              </option>
            ))}
          </Select>
        </div>
        <Button disabled={pending || !show} onClick={() => onPick("one_show", show)}>
          Make it
        </Button>
      </Card>
      <Card icon={<CalendarHeart className="h-5 w-5" aria-hidden />} title="A holiday" text="The holiday's episodes and films all day for the season, the library's best the rest of the year.">
        <div className="min-w-32 flex-1">
          <Select label="Holiday" value={holiday} onChange={(event) => setHoliday(event.target.value)}>
            {HOLIDAYS.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </Select>
        </div>
        <Button disabled={pending} onClick={() => onPick("holiday", holiday)}>
          Make it
        </Button>
      </Card>
      <Card icon={<PencilRuler className="h-5 w-5" aria-hidden />} title="From scratch" text="An empty channel: choose its mix, then add dayparts, appointments and specials.">
        <Button variant="secondary" disabled={pending} onClick={onScratch}>
          Start blank
        </Button>
      </Card>
    </div>
  );
}

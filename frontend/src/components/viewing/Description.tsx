import { Fragment, useState, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { cn } from "@/lib/cn";

const TOKEN = /(https?:\/\/[^\s<>"')\]]+)|(?<![\d:])((?:\d{1,2}:)?\d{1,2}:\d{2})(?![\d:])/g;

function seconds(stamp: string): number {
  return stamp.split(":").reduce((total, part) => total * 60 + Number(part), 0);
}

/** Links and timestamps in a line of text become clickable (PROPOSAL §5.4). */
export function linkify(text: string, videoId?: string): ReactNode[] {
  const out: ReactNode[] = [];
  let last = 0;
  for (const match of text.matchAll(TOKEN)) {
    const index = match.index ?? 0;
    if (index > last) out.push(text.slice(last, index));
    const [whole, url, stamp] = match;
    if (url) {
      out.push(
        <a key={index} href={url} target="_blank" rel="noopener noreferrer nofollow" className="text-primary underline-offset-4 hover:underline">
          {url}
        </a>,
      );
    } else if (stamp && videoId) {
      out.push(
        <Link key={index} to={`/video/${videoId}?t=${seconds(stamp)}`} className="text-primary underline-offset-4 hover:underline">
          {stamp}
        </Link>,
      );
    } else {
      out.push(whole);
    }
    last = index + whole.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

/** A description, a few lines until asked for all of it — or all of it until asked for less (`defaultOpen`). */
export function Description({
  text,
  videoId,
  className,
  defaultOpen = false,
}: {
  text: string;
  videoId?: string;
  className?: string;
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen);
  const long = text.split("\n").length > 4 || text.length > 320;
  return (
    <div className={cn("rounded-[var(--radius-card)] bg-surface p-3 text-sm text-foreground/90", className)}>
      <div className={cn("whitespace-pre-line break-words", !open && long && "line-clamp-4")}>
        {text.split("\n").map((line, index) => (
          <Fragment key={index}>
            {index > 0 ? "\n" : null}
            {linkify(line, videoId)}
          </Fragment>
        ))}
      </div>
      {long ? (
        <button type="button" onClick={() => setOpen((value) => !value)} className="mt-2 text-sm font-medium text-foreground">
          {open ? "Show less" : "Show more"}
        </button>
      ) : null}
    </div>
  );
}

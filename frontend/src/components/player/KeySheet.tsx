const KEYS: [string, string][] = [
  ["Space / K", "Play or pause"],
  ["J / L", "Back or forward 10 seconds"],
  ["← / →", "Back or forward 5 seconds"],
  ["↑ / ↓", "Volume"],
  ["0–9", "Jump to 0%–90%"],
  [", / .", "Previous or next frame (paused)"],
  ["< / >", "Slower or faster"],
  ["M", "Mute"],
  ["C", "Subtitles on or off"],
  ["F", "Full screen"],
  ["T", "Full width (a video on its page)"],
  ["I", "Mini-player"],
  ["X", "Swap with picture in picture"],
  ["Shift + N", "Next episode"],
  ["R", "Related"],
  ["S", "Stats for nerds"],
  ["?", "This list"],
  ["Esc", "Back (keeps playing in the corner), or out of full window"],
];

/** The keyboard map (PROPOSAL §7.3), on ?. */
export function KeySheet({ onClose }: { onClose: () => void }) {
  return (
    <div className="pointer-events-auto absolute inset-0 flex items-center justify-center bg-background/70" onClick={onClose}>
      <div className="w-full max-w-md rounded-[var(--radius-card)] bg-surface p-5 shadow-xl ring-1 ring-border" onClick={(event) => event.stopPropagation()}>
        <h2 className="mb-3 font-semibold text-foreground">Keyboard shortcuts</h2>
        <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 text-sm">
          {KEYS.map(([key, action]) => (
            <div key={key} className="contents">
              <dt className="font-mono text-foreground">{key}</dt>
              <dd className="text-muted">{action}</dd>
            </div>
          ))}
        </dl>
      </div>
    </div>
  );
}

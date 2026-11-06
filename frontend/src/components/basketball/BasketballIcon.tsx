/** A basketball, drawn like lucide's icons: Basketball's sidebar link. */
export function BasketballIcon({ className, "aria-hidden": ariaHidden }: { className?: string; "aria-hidden"?: boolean }) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden={ariaHidden}
    >
      <circle cx="12" cy="12" r="10" />
      <path d="M2 12h20" />
      <path d="M12 2v20" />
      <path d="M4.9 4.9a10 10 0 0 1 0 14.2" />
      <path d="M19.1 4.9a10 10 0 0 0 0 14.2" />
    </svg>
  );
}

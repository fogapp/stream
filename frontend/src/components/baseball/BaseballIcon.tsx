/** A baseball, drawn like lucide's icons (which have none): Baseball's sidebar link. */
export function BaseballIcon({ className, "aria-hidden": ariaHidden }: { className?: string; "aria-hidden"?: boolean }) {
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
      <path d="M5.6 4.4a10 10 0 0 1 0 15.2" />
      <path d="M18.4 4.4a10 10 0 0 0 0 15.2" />
    </svg>
  );
}

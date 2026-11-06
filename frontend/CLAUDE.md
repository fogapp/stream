# Stream frontend — non-negotiables

Two surfaces in one SPA (see the repo `CLAUDE.md` and PROPOSAL §7): the
**viewing experience** — home, browse, detail pages, the player — which is
dark-first, image-led and keyboard-complete; and the **admin surface** —
settings, activity, the Playback decisions page — which keeps hook's
operations-console discipline. The player never explains itself on screen;
reasons live on the admin page.

## The cardinal rule

Every color goes through a semantic token defined in `src/index.css`:
`background`, `surface`, `surface-raised`, `foreground`, `muted`, `border`,
`input`, `primary`, `primary-hover`, `primary-foreground`, `positive`,
`negative`, `negative-foreground`, `warning`.

**Never** write a raw palette class (`bg-blue-500`, `text-gray-700`,
`border-red-200`) in `.tsx` *or* `.ts`. Themes are token overrides; components
never branch on theme.

Guard (runs in CI, and catches the `.ts` helper case manor's audit missed):

```bash
bin/design-guard
```

## Components

- Build a `ui/` primitive before a page needs it twice. Manor ended up with
  279 raw `<button>`s against 57 `<Button>`s by deferring this.
- Variants are plain object maps + `cn()`, not CVA.
- Controls are primitives too: `Checkbox`, `Radio`/`RadioCard`, `Toggle`,
  `IconButton` (its `label` is required), `DisclosureButton`,
  `RevealedSecret`. A raw `<input type="checkbox">` or an icon-only
  `<button>` in a page is a missing primitive.
- Forms use `useFormMutation` with `FormError`/`FormFooter`; list screens use
  `QueryState`; a connection's Test uses `useTestConnection` + `TestButton`.
  A form starts from the server's values and does not re-sync on refetch.
- Enum display maps live in `lib/`, one map per question:
  `X_LABELS: Record<X, string>` and `X_TONES: Record<X, BadgeTone>`. A value
  that needs more than a label (a hint too) gets `X_OPTIONS`.
- A failed query must never render as an empty list — every list screen uses
  `LoadingState` / `ErrorState` (with `onRetry`) / `EmptyState`.
- Controls: `h-8/9/10`, `rounded-[var(--radius-control)]`; cards
  `rounded-[var(--radius-card)]`. Focus is the global `:focus-visible` ring —
  don't override it per component.

## Data

- Query keys come from `lib/queryKeys.ts`. Each resource exposes `all` as the
  invalidation prefix; factories nest under it so one invalidate cascades.
  No inline key literals.
- `api.get<T>` trusts `T` — there is no runtime validation by design. When a
  serializer changes, `src/types` changes in the same commit.
- Closed vocabularies are derived unions: `as const` list → union type → keyed
  maps, mirroring the backend `T::Enum`.

## Checks

```bash
npm run lint
npm run build      # tsc -b + vite build (bare `tsc --noEmit` checks nothing —
                   # the root tsconfig is references-only)
npm test -- --run
```

## Small screens

Stream is used from a phone (browsing, casting a glance at what's new,
fixing a match). The sidebar folds into a drawer below `lg`; page padding is
`px-4 sm:px-6 lg:px-8`; `Tabs` and `Segmented` scroll sideways rather than
wrap. A table whose row is a record gets a card layout below `md`/`lg`:
`DataTable`'s `card` + `cardBelow`, or
`useMediaQuery(BREAKPOINTS.*)` by hand where the rows aren't a `DataTable`
— a fluid `DataTable` drops columns from the array the same way,
since `display: none` can't give a `table-fixed` column's width back. Check
a page at 390px before shipping it: nothing may scroll sideways.

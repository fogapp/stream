import { createContext, useContext, useState, type ComponentType, type ReactNode } from "react";
import { NavLink, useNavigate } from "react-router-dom";
import { ArrowDown, ArrowUp, ChevronRight, Eye, EyeOff, RefreshCw, Search, Settings as SettingsIcon } from "lucide-react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { cn } from "@/lib/cn";
import { arrange, move } from "@/lib/sidebar";
import { useAuth } from "@/hooks/useAuth";
import { ActionMenu, ActionMenuItem, ActionMenuSeparator } from "@/components/ui/ActionMenu";
import { toast } from "@/components/ui/Toast";
import type { Library, SidebarLayout } from "@/types";

export interface SidebarItem {
  /** What the profile's arrangement calls it: `live`, `library:<id>`. */
  key: string;
  to: string;
  label: string;
  icon: ComponentType<{ className?: string; "aria-hidden"?: boolean }>;
  end: boolean;
  library?: Library;
}

const EMPTY: SidebarLayout = { order: [], hidden: [] };

/** True when the desktop sidebar is folded to its icons: labels go to screen readers and tooltips. */
export const SidebarCollapsed = createContext(false);

/**
 * The sidebar's links below Home, in the order this profile put them. Each
 * has a "…" (on hover, or always on a touch screen) to move or hide it —
 * and, for an admin, to scan a library. Hidden ones wait under "More".
 */
export function SidebarNav({ items, loading = false }: { items: SidebarItem[]; loading?: boolean }) {
  const queryClient = useQueryClient();
  const sidebar = useQuery({ queryKey: keys.sidebar.layout(), queryFn: ({ signal }) => api.get<SidebarLayout>("/sidebar", { signal }) });
  const layout = sidebar.data ?? EMPTY;
  const save = useMutation({
    mutationFn: (next: SidebarLayout) => api.put<SidebarLayout>("/sidebar", next),
    // The sidebar answers at once; the server catches up.
    onMutate: (next) => queryClient.setQueryData(keys.sidebar.layout(), next),
    onSettled: () => queryClient.invalidateQueries({ queryKey: keys.sidebar.all }),
  });
  const [moreOpen, setMoreOpen] = useState(false);
  const collapsed = useContext(SidebarCollapsed);

  const arranged = arrange(items, layout.order);
  const shown = arranged.filter((item) => !layout.hidden.includes(item.key));
  const hidden = arranged.filter((item) => layout.hidden.includes(item.key));
  const shownKeys = shown.map(({ key }) => key);

  const actions: ItemActions = {
    move: (key, by) => save.mutate({ order: move(shownKeys, key, by), hidden: layout.hidden }),
    hide: (key) => save.mutate({ order: shownKeys.filter((shownKey) => shownKey !== key), hidden: [...layout.hidden, key] }),
    // Dropped from the order too, so it comes back to its default place.
    show: (key) => save.mutate({ order: shownKeys, hidden: layout.hidden.filter((hiddenKey) => hiddenKey !== key) }),
  };

  // Nothing until the libraries and this profile's order are in: rows that
  // arrive all at once don't move, where the static links drawn first and
  // pushed down by each library were the layout shift on every page load.
  if (loading || sidebar.isPending) return null;

  return (
    <>
      {shown.map((item, index) => (
        <SidebarRow key={item.key} item={item}>
          {(close) => (
            <>
              <ActionMenuItem icon={<ArrowUp className="h-4 w-4" aria-hidden />} disabled={index === 0} onSelect={() => (actions.move(item.key, -1), close())}>
                Move up
              </ActionMenuItem>
              <ActionMenuItem icon={<ArrowDown className="h-4 w-4" aria-hidden />} disabled={index === shown.length - 1} onSelect={() => (actions.move(item.key, 1), close())}>
                Move down
              </ActionMenuItem>
              <ActionMenuItem icon={<EyeOff className="h-4 w-4" aria-hidden />} onSelect={() => (actions.hide(item.key), close())}>
                Hide from sidebar
              </ActionMenuItem>
              {item.library ? <LibraryActions library={item.library} close={close} /> : null}
            </>
          )}
        </SidebarRow>
      ))}
      {hidden.length > 0 ? (
        <div className="pt-2">
          <button
            type="button"
            aria-expanded={moreOpen}
            onClick={() => setMoreOpen((open) => !open)}
            title={collapsed ? `More (${hidden.length})` : undefined}
            className={cn(
              "flex w-full items-center gap-2.5 rounded-[var(--radius-control)] px-3 py-2 text-xs font-medium uppercase tracking-wide text-muted hover:text-foreground",
              collapsed && "justify-center px-0",
            )}
          >
            <ChevronRight className={cn("h-4 w-4 transition-transform", moreOpen && "rotate-90")} aria-hidden />
            <span className={cn(collapsed && "sr-only")}>More ({hidden.length})</span>
          </button>
          {moreOpen
            ? hidden.map((item) => (
                <SidebarRow key={item.key} item={item}>
                  {(close) => (
                    <>
                      <ActionMenuItem icon={<Eye className="h-4 w-4" aria-hidden />} onSelect={() => (actions.show(item.key), close())}>
                        Show in sidebar
                      </ActionMenuItem>
                      {item.library ? <LibraryActions library={item.library} close={close} /> : null}
                    </>
                  )}
                </SidebarRow>
              ))
            : null}
        </div>
      ) : null}
    </>
  );
}

interface ItemActions {
  move: (key: string, by: -1 | 1) => void;
  hide: (key: string) => void;
  show: (key: string) => void;
}

export function SidebarLink({ item, className }: { item: Pick<SidebarItem, "to" | "label" | "icon" | "end">; className?: string }) {
  const { to, icon: Icon, end } = item;
  const collapsed = useContext(SidebarCollapsed);
  return (
    <NavLink
      to={to}
      end={end}
      title={collapsed ? item.label : undefined}
      className={({ isActive }) =>
        cn(
          "flex items-center gap-2.5 rounded-[var(--radius-control)] px-3 py-2.5 text-sm lg:py-2",
          isActive ? "bg-primary/10 font-medium text-primary" : "text-muted hover:bg-surface-raised hover:text-foreground",
          className,
          collapsed && "justify-center px-0",
        )
      }
    >
      <Icon className="h-4 w-4 shrink-0" aria-hidden />
      <span className={cn("min-w-0 truncate", collapsed && "sr-only")}>{item.label}</span>
    </NavLink>
  );
}

function SidebarRow({ item, children }: { item: SidebarItem; children: (close: () => void) => ReactNode }) {
  // The rail has no room for a "…"; expanding the sidebar brings it back.
  if (useContext(SidebarCollapsed)) return <SidebarLink item={item} />;
  return (
    <div className="group relative">
      <SidebarLink item={item} className="pr-10" />
      {/* Shown on hover or focus where there's a pointer; always on a touch screen. */}
      <ActionMenu
        label={`More for ${item.label}`}
        className={cn(
          "absolute right-1 top-1/2 h-7 w-7 -translate-y-1/2 rounded-[var(--radius-control)] bg-transparent text-muted hover:bg-surface hover:text-foreground",
          "opacity-0 group-hover:opacity-100 focus-visible:opacity-100 aria-expanded:opacity-100 [@media(hover:none)]:opacity-100",
        )}
      >
        {children}
      </ActionMenu>
    </div>
  );
}

/** What an admin can do to a library from the sidebar. */
function LibraryActions({ library, close }: { library: Library; close: () => void }) {
  const { user } = useAuth();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const refresh = () => queryClient.invalidateQueries({ queryKey: keys.libraries.all });
  const scan = useMutation({
    mutationFn: () => api.post(`/libraries/${library.id}/scan`),
    onSuccess: () => {
      toast.info(`Scanning ${library.name}…`);
      void refresh();
    },
  });
  const rematch = useMutation({
    mutationFn: () => api.post(`/libraries/${library.id}/rematch`),
    onSuccess: () => toast.info(`Matching ${library.name}'s unmatched titles again…`),
  });
  if (user?.role !== "admin") return null;

  return (
    <>
      <ActionMenuSeparator label="Library" />
      <ActionMenuItem icon={<RefreshCw className="h-4 w-4" aria-hidden />} disabled={library.scanning} onSelect={() => (scan.mutate(), close())}>
        {library.scanning ? "Scanning now…" : "Scan library files"}
      </ActionMenuItem>
      {library.kind === "movies" || library.kind === "shows" ? (
        <ActionMenuItem icon={<Search className="h-4 w-4" aria-hidden />} onSelect={() => (rematch.mutate(), close())}>
          Match unmatched again
        </ActionMenuItem>
      ) : null}
      <ActionMenuItem icon={<SettingsIcon className="h-4 w-4" aria-hidden />} onSelect={() => (close(), navigate("/settings?tab=libraries"))}>
        Edit library
      </ActionMenuItem>
    </>
  );
}

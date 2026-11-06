import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowLeft, Ban, Clapperboard, ImagePlus, Info, Pencil } from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { ActionMenu, ActionMenuItem, ActionMenuSeparator } from "@/components/ui/ActionMenu";
import { ArtworkPickerDialog } from "@/components/viewing/ArtworkPicker";
import { useHideFromProfile } from "@/components/viewing/HideFromProfile";
import { ShowInfoDialog } from "@/components/viewing/ShowInfo";
import { TrailerDialog } from "@/components/viewing/TrailerButton";
import type { ShowDetail } from "@/types";

type Opened = "trailer" | "artwork" | "info";

/**
 * The "…" on a show's page: the trailer, an admin's edits (details,
 * pictures, Info), and Hide from me. What it opens lives outside the menu,
 * which is gone by the time a dialog shows.
 */
export function ShowActions({ show, editing, onEdit }: { show: ShowDetail; editing: boolean; onEdit: () => void }) {
  const navigate = useNavigate();
  const { user } = useAuth();
  const admin = user?.role === "admin";
  // Off this page first: it's one the profile can no longer open.
  const hiding = useHideFromProfile({ kind: "show", id: show.id, title: show.title }, () => navigate("/", { replace: true }));
  const [opened, setOpened] = useState<Opened | null>(null);
  const [confirmingHide, setConfirmingHide] = useState(false);
  const trailer = show.trailer;
  if (!trailer && !admin && !hiding) return null;

  const open = (what: Opened, close: () => void) => {
    close();
    setOpened(what);
  };

  return (
    <>
      <ActionMenu
        label={`More for ${show.title}`}
        className="w-auto self-center rounded-[var(--radius-control)] border border-border bg-surface-raised px-3 text-muted hover:text-foreground aria-expanded:text-foreground"
      >
        {(close) =>
          confirmingHide && hiding ? (
            <>
              <ActionMenuItem icon={<ArrowLeft className="h-4 w-4" aria-hidden />} onSelect={() => setConfirmingHide(false)} autoFocus>
                Back
              </ActionMenuItem>
              <ActionMenuSeparator label={`Hide from ${hiding.profileName} everywhere?`} />
              <ActionMenuItem
                icon={<Ban className="h-4 w-4" aria-hidden />}
                disabled={hiding.pending}
                onSelect={() => {
                  setConfirmingHide(false);
                  close();
                  hiding.hide();
                }}
              >
                Hide {show.title}
              </ActionMenuItem>
            </>
          ) : (
            <>
              {trailer ? (
                <ActionMenuItem icon={<Clapperboard className="h-4 w-4" aria-hidden />} onSelect={() => open("trailer", close)}>
                  Trailer
                </ActionMenuItem>
              ) : null}
              {admin ? (
                <>
                  {trailer ? <ActionMenuSeparator /> : null}
                  <ActionMenuItem
                    icon={<Pencil className="h-4 w-4" aria-hidden />}
                    onSelect={() => {
                      close();
                      onEdit();
                    }}
                  >
                    {editing ? "Stop editing details" : "Edit details"}
                  </ActionMenuItem>
                  <ActionMenuItem icon={<ImagePlus className="h-4 w-4" aria-hidden />} onSelect={() => open("artwork", close)}>
                    Change pictures
                  </ActionMenuItem>
                  <ActionMenuItem icon={<Info className="h-4 w-4" aria-hidden />} onSelect={() => open("info", close)}>
                    Info
                  </ActionMenuItem>
                </>
              ) : null}
              {hiding ? (
                <>
                  {trailer || admin ? <ActionMenuSeparator /> : null}
                  <ActionMenuItem icon={<Ban className="h-4 w-4" aria-hidden />} onSelect={() => setConfirmingHide(true)}>
                    Hide from me…
                  </ActionMenuItem>
                </>
              ) : null}
            </>
          )
        }
      </ActionMenu>
      {opened === "trailer" && trailer ? <TrailerDialog trailer={trailer} onClose={() => setOpened(null)} /> : null}
      {opened === "artwork" ? <ArtworkPickerDialog ownerType="show" ownerId={show.id} onClose={() => setOpened(null)} /> : null}
      {opened === "info" ? <ShowInfoDialog showId={show.id} onClose={() => setOpened(null)} /> : null}
    </>
  );
}

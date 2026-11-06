import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useSearchParams } from "react-router-dom";
import { ArrowLeft, ChevronRight, Plus } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { profilesQuery } from "@/lib/queries";
import { useFormMutation } from "@/hooks/useFormMutation";
import { ProfileAvatar } from "@/components/profiles/ProfileAvatar";
import { HiddenTitles, TaggedTitles } from "@/components/settings/ProfileContent";
import { OPEN, ProfileRestrictions, type Restrictions } from "@/components/settings/ProfileRestrictions";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Checkbox } from "@/components/ui/Checkbox";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { FormError, FormFooter } from "@/components/ui/Form";
import { IconButton } from "@/components/ui/IconButton";
import { Input } from "@/components/ui/Input";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import type { ProfileInfo } from "@/types";

/** Profile colours: data a person picks, shown only as a profile's avatar. */
const COLORS = ["#e5a50a", "#3584e4", "#2ec27e", "#e01b24", "#9141ac", "#ff7800", "#1a5fb4", "#c64600"] as const;
const AVATARS = ["", "🦊", "🐼", "🦁", "🐙", "🚀", "🌈", "⚽", "🎸", "🦖", "🐝", "🌻"] as const;

/**
 * Settings › Profiles (PROPOSAL §7.4): who watches here. Each profile opens
 * its own page (in the URL, so it survives a refresh): its details and PIN,
 * what it may see, what's hidden from it and what's tagged for it. Admins only.
 */
export function Profiles() {
  const profiles = useQuery(profilesQuery());
  const [params, setParams] = useSearchParams();
  const [creating, setCreating] = useState(false);
  const openId = params.get("profile");

  function open(id: string | null) {
    const next = new URLSearchParams(params);
    if (id) next.set("profile", id);
    else next.delete("profile");
    setParams(next, { replace: true });
  }

  if (openId) {
    return (
      <QueryState query={profiles} errorMessage="Could not load profiles.">
        {(list) => {
          const profile = list.find((row) => row.id === openId);
          return profile ? (
            <ProfilePage key={profile.id} profile={profile} canDelete={list.length > 1} onBack={() => open(null)} />
          ) : (
            <EmptyState title="That profile is gone" action={<Button onClick={() => open(null)}>All profiles</Button>} />
          );
        }}
      </QueryState>
    );
  }

  return (
    <Card>
      <CardHeader
        title="Profiles"
        description="Each person's watch history, ratings, lists and subscriptions. Open one to change what it sees and what's hidden from it."
        actions={
          creating ? null : (
            <Button size="sm" onClick={() => setCreating(true)}>
              <Plus className="h-4 w-4" aria-hidden />
              New profile
            </Button>
          )
        }
      />
      <CardBody className="space-y-4">
        {creating ? <ProfileForm profile={null} onDone={() => setCreating(false)} /> : null}
        <QueryState query={profiles} errorMessage="Could not load profiles.">
          {(list) => (
            <ul className="divide-y divide-border">
              {list.map((profile) => (
                <li key={profile.id}>
                  <button
                    type="button"
                    onClick={() => open(profile.id)}
                    className="flex w-full items-center gap-3 rounded-[var(--radius-control)] py-2.5 text-left hover:bg-surface-raised"
                  >
                    <ProfileAvatar profile={profile} />
                    <span className="min-w-0 flex-1 truncate font-medium text-foreground">{profile.name}</span>
                    <ProfileBadges profile={profile} />
                    <ChevronRight className="h-4 w-4 shrink-0 text-muted" aria-hidden />
                  </button>
                </li>
              ))}
            </ul>
          )}
        </QueryState>
      </CardBody>
    </Card>
  );
}

function ProfileBadges({ profile }: { profile: ProfileInfo }) {
  return (
    <>
      {profile.kind === "kid" ? <Badge tone="info">Kid</Badge> : null}
      {profile.curated ? <Badge>Curated</Badge> : null}
      {profile.has_pin ? <Badge>PIN</Badge> : null}
    </>
  );
}

/** One profile, everything about it in one place. */
function ProfilePage({ profile, canDelete, onBack }: { profile: ProfileInfo; canDelete: boolean; onBack: () => void }) {
  const limited = profile.curated || profile.max_rating_age !== null;
  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center gap-3">
        <Button variant="ghost" size="sm" onClick={onBack}>
          <ArrowLeft className="h-4 w-4" aria-hidden />
          All profiles
        </Button>
        <ProfileAvatar profile={profile} size="md" />
        <h2 className="min-w-0 flex-1 truncate text-xl font-semibold text-foreground">{profile.name}</h2>
        <ProfileBadges profile={profile} />
        {canDelete ? <DeleteProfile profile={profile} onDeleted={onBack} /> : null}
      </div>
      <Card>
        <CardHeader title="Profile" description="Name, picture, PIN, what it may see and how it plays." />
        <CardBody>
          <ProfileForm profile={profile} onDone={onBack} framed={false} />
        </CardBody>
      </Card>
      <HiddenTitles profile={profile} />
      {limited ? <TaggedTitles profile={profile} /> : null}
    </div>
  );
}

function DeleteProfile({ profile, onDeleted }: { profile: ProfileInfo; onDeleted: () => void }) {
  const queryClient = useQueryClient();
  const remove = useMutation({
    mutationFn: () => api.delete(`/profiles/${profile.id}`),
    onSuccess: () => {
      onDeleted();
      void queryClient.invalidateQueries({ queryKey: keys.profiles.all });
    },
  });
  return (
    <ConfirmButton question={`Delete ${profile.name}, with its history and lists?`} onConfirm={() => remove.mutate()}>
      Delete
    </ConfirmButton>
  );
}

function ProfileForm({ profile, onDone, framed = true }: { profile: ProfileInfo | null; onDone: () => void; framed?: boolean }) {
  const queryClient = useQueryClient();
  const [name, setName] = useState(profile?.name ?? "");
  const [color, setColor] = useState(profile?.color ?? COLORS[0]);
  const [avatar, setAvatar] = useState(profile?.avatar ?? "");
  const [pin, setPin] = useState("");
  const [clearPin, setClearPin] = useState(false);
  const [restrictions, setRestrictions] = useState<Restrictions>(() => {
    if (!profile) return OPEN;
    const { kind, max_rating_age, allow_unrated, library_ids, curated, up_next_seconds, always_skip_intro, always_skip_credits, still_watching_after } = profile;
    return { kind, max_rating_age, allow_unrated, library_ids, curated, up_next_seconds, always_skip_intro, always_skip_credits, still_watching_after };
  });
  const save = useFormMutation({
    fallback: "Couldn't save the profile.",
    mutationFn: () => {
      const body: Record<string, unknown> = { name, color, avatar: avatar || null, ...restrictions };
      if (pin) body.pin = pin;
      else if (clearPin) body.pin = "";
      return profile ? api.patch(`/profiles/${profile.id}`, body) : api.post("/profiles", body);
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: keys.profiles.all });
      onDone();
    },
  });

  return (
    <form
      className={framed ? "space-y-4 rounded-[var(--radius-card)] border border-border p-4" : "space-y-4"}
      onSubmit={(event) => {
        event.preventDefault();
        save.mutate();
      }}
    >
      <div className="flex items-center gap-4">
        <ProfileAvatar profile={{ name: name || "?", color, avatar: avatar || null }} size="md" />
        <div className="flex-1">
          <Input label="Name" name="profile-name" value={name} onChange={(event) => setName(event.target.value)} required maxLength={40} />
        </div>
      </div>
      <fieldset>
        <legend className="mb-2 text-sm font-medium text-foreground">Colour</legend>
        <div className="flex flex-wrap gap-2">
          {COLORS.map((choice) => (
            <IconButton
              key={choice}
              label={`Colour ${choice}`}
              aria-pressed={color === choice}
              onClick={() => setColor(choice)}
              className={color === choice ? "rounded-full p-0.5 ring-2 ring-foreground" : "rounded-full p-0.5"}
            >
              <span className="block h-7 w-7 rounded-full" style={{ backgroundColor: choice }} />
            </IconButton>
          ))}
        </div>
      </fieldset>
      <fieldset>
        <legend className="mb-2 text-sm font-medium text-foreground">Picture</legend>
        <div className="flex flex-wrap gap-2">
          {AVATARS.map((choice) => (
            <Button
              key={choice || "initial"}
              type="button"
              size="sm"
              variant={avatar === choice ? "secondary" : "ghost"}
              aria-pressed={avatar === choice}
              onClick={() => setAvatar(choice)}
            >
              {choice || "Initial"}
            </Button>
          ))}
        </div>
      </fieldset>
      <Input
        label={profile?.has_pin ? "New PIN" : "PIN"}
        name="profile-pin"
        type="password"
        inputMode="numeric"
        autoComplete="new-password"
        value={pin}
        onChange={(event) => setPin(event.target.value.replace(/\D/g, "").slice(0, 8))}
        hint="4 to 8 digits. Leave empty for no PIN."
      />
      {profile?.has_pin ? (
        <Checkbox label="Remove the PIN" checked={clearPin} onChange={setClearPin} />
      ) : null}
      <ProfileRestrictions value={restrictions} onChange={setRestrictions} />
      <FormError message={save.errorMessage} />
      <FormFooter label={profile ? "Save" : "Create profile"} pending={save.isPending} onCancel={onDone} />
    </form>
  );
}

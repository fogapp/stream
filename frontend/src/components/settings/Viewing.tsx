import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useDraft } from "@/hooks/useDraft";
import { useFormMutation } from "@/hooks/useFormMutation";
import { Button } from "@/components/ui/Button";
import { FormError } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { Toggle } from "@/components/ui/Toggle";
import { adaptiveQuality, setAdaptiveQuality } from "@/lib/capabilities";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { useTestConnection } from "@/hooks/useTestConnection";
import { TestResultLine } from "@/components/settings/TestResultLine";
import { SPONSOR_ACTION_LABELS, SPONSOR_CATEGORY_LABELS } from "@/lib/libraries";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { QueryState } from "@/components/ui/PageState";
import { Segmented } from "@/components/ui/Segmented";
import { HiddenTitles } from "@/components/settings/ProfileContent";
import { TraktLinkCard } from "@/components/settings/TraktLink";
import { useProfile } from "@/hooks/useProfile";
import {
  SPONSOR_ACTIONS,
  SPONSOR_CATEGORIES,
  type NotificationPreferences,
  type RemoteDevice,
  type SponsorAction,
  type SponsorCategory,
} from "@/types";

type Actions = Record<SponsorCategory, SponsorAction>;

/** Settings › Viewing: how this profile watches (PROPOSAL §7.4). */
export function Viewing() {
  const { profile } = useProfile();
  return (
    <div className="space-y-6">
      <NotificationsCard />
      {profile && profile.kind !== "kid" ? <HiddenTitles profile={profile} self /> : null}
      {profile && profile.kind !== "kid" ? <TraktLinkCard /> : null}
      <YoutubeCard />
      <SponsorBlockCard />
      <ThisBrowserCard />
    </div>
  );
}

function NotificationsCard() {
  const queryClient = useQueryClient();
  const preferences = useQuery({
    queryKey: keys.notificationPreferences.current(),
    queryFn: ({ signal }) => api.get<NotificationPreferences>("/notification_preferences", { signal }),
  });
  const draft = useDraft(preferences.data, { ntfy_topic: "" });
  const save = useFormMutation({
    fallback: "Couldn't save.",
    mutationFn: (change: Partial<NotificationPreferences>) => api.patch<NotificationPreferences>("/notification_preferences", change),
    onSuccess: (data) => queryClient.setQueryData(keys.notificationPreferences.current(), data),
  });
  const test = useTestConnection("/notification_preferences/test", keys.notificationPreferences.all);

  return (
    <Card>
      <CardHeader title="Notifications" description="Pushed to your phone by ntfy: this profile's own topic, and what to hear about." />
      <CardBody>
        <QueryState query={preferences} errorMessage="Could not load notification settings.">
          {(data) =>
            data.ntfy_configured ? (
              <div className="space-y-4">
                <form
                  className="flex max-w-xl items-end gap-2"
                  onSubmit={(event) => {
                    event.preventDefault();
                    // Untouched, the stored topic goes back as it is (none stays none).
                    save.mutate({ ntfy_topic: draft.dirty ? draft.value("ntfy_topic") : data.ntfy_topic });
                  }}
                >
                  <div className="flex-1">
                    <Input label="ntfy topic" value={draft.value("ntfy_topic")} onChange={(event) => draft.set("ntfy_topic", event.target.value)} placeholder="e.g. stream-alex" />
                  </div>
                  <Button type="submit" variant="secondary" disabled={save.isPending}>
                    Save
                  </Button>
                  <Button type="button" variant="ghost" onClick={test.run} disabled={!data.ntfy_topic || test.pending}>
                    {test.pending ? "Sending…" : "Send a test"}
                  </Button>
                </form>
                <FormError message={save.errorMessage} />
                <TestResultLine ok={test.result?.ok ?? null} message={test.result?.message ?? null} />
                <Toggle label="New episodes of shows I'm watching" checked={data.notify_new_episodes} onChange={(on) => save.mutate({ notify_new_episodes: on })} />
                <Toggle label="New videos from my subscriptions" checked={data.notify_subscriptions} onChange={(on) => save.mutate({ notify_subscriptions: on })} />
              </div>
            ) : (
              <p className="text-sm text-muted">No ntfy server is set up yet — an admin adds it in Settings › General.</p>
            )
          }
        </QueryState>
      </CardBody>
    </Card>
  );
}

function YoutubeCard() {
  const queryClient = useQueryClient();
  const { profile } = useProfile();
  // Starts from the profile's value; the switch moves at once, and back if saving fails.
  const [autoplay, setAutoplay] = useState(profile?.autoplay_videos ?? false);
  const save = useMutation({
    mutationFn: (on: boolean) => api.patch<{ autoplay_videos: boolean }>("/viewing_preferences", { autoplay_videos: on }),
    onSuccess: (data) => {
      setAutoplay(data.autoplay_videos);
      void queryClient.invalidateQueries({ queryKey: keys.profiles.current() });
    },
    onError: (_error, on) => setAutoplay(!on),
  });
  if (!profile) return null;
  return (
    <Card>
      <CardHeader title="YouTube" description="How this profile's videos start." />
      <CardBody className="space-y-2">
        <Toggle
          label="Play videos as soon as they open"
          hint="Opening a video starts it, even over something already playing. If the browser won't play sound on its own, it starts muted with an Unmute button."
          checked={autoplay}
          onChange={(on) => {
            setAutoplay(on);
            save.mutate(on);
          }}
        />
        {save.isError ? <FormError message="Couldn't save." /> : null}
      </CardBody>
    </Card>
  );
}

function SponsorBlockCard() {
  const queryClient = useQueryClient();
  const preferences = useQuery({
    queryKey: keys.sponsorblock.preferences(),
    queryFn: ({ signal }) => api.get<{ actions: Actions }>("/sponsorblock_preferences", { signal }),
  });
  const save = useMutation({
    mutationFn: (change: Partial<Actions>) => api.patch<{ actions: Actions }>("/sponsorblock_preferences", { actions: change }),
    onSuccess: (data) => queryClient.setQueryData(keys.sponsorblock.preferences(), data),
  });
  const segments = SPONSOR_ACTIONS.map((key) => ({ key, label: SPONSOR_ACTION_LABELS[key] }));

  return (
    <Card>
      <CardHeader
        title="SponsorBlock"
        description="For YouTube videos in libraries with SponsorBlock on: what this profile does when a marked part comes up."
      />
      <CardBody>
        <QueryState query={preferences} errorMessage="Could not load SponsorBlock settings.">
          {(data) => (
            <ul className="divide-y divide-border">
              {SPONSOR_CATEGORIES.map((category) => (
                <li key={category} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center sm:justify-between">
                  <div>
                    <p className="text-sm font-medium text-foreground">{SPONSOR_CATEGORY_LABELS[category].label}</p>
                    <p className="text-xs text-muted">{SPONSOR_CATEGORY_LABELS[category].hint}</p>
                  </div>
                  <Segmented
                    segments={segments}
                    value={data.actions[category]}
                    onChange={(action) => save.mutate({ [category]: action })}
                    label={`${SPONSOR_CATEGORY_LABELS[category].label}: what to do`}
                  />
                </li>
              ))}
            </ul>
          )}
        </QueryState>
      </CardBody>
    </Card>
  );
}

/** Kept in this browser alone: it's about this browser's connection. */
function AdaptiveToggle() {
  const [on, setOn] = useState(adaptiveQuality);
  return (
    <Toggle
      label="Drop to a smaller picture on a weak connection"
      hint="For a phone or laptop on patchy Wi-Fi. Streams from outside home always can; at home nothing needs it."
      checked={on}
      onChange={(next) => {
        setAdaptiveQuality(next);
        setOn(next);
      }}
    />
  );
}

/**
 * This browser as a screen (PROPOSAL §11 Phase 6): what it's called, and
 * whether the app on a phone, or an agent over MCP, may play things on it.
 * A TV on /tv always may.
 */
function ThisBrowserCard() {
  const queryClient = useQueryClient();
  const device = useQuery({ queryKey: keys.remote.thisDevice(), queryFn: ({ signal }) => api.get<RemoteDevice>("/remote/this_device", { signal }) });
  const draft = useDraft(device.data, { label: "" });
  const save = useFormMutation({
    fallback: "Couldn't save.",
    mutationFn: (change: { label?: string; remote_control?: boolean }) => api.patch<RemoteDevice>("/remote/this_device", change),
    onSuccess: (data) => queryClient.setQueryData(keys.remote.thisDevice(), data),
  });
  return (
    <Card>
      <CardHeader title="This browser" description="Let other screens, or an assistant, play things here: “play Severance in the living room”." />
      <CardBody>
        <QueryState query={device} errorMessage="Couldn't load this browser's settings.">
          {(current) => (
            <div className="max-w-xl space-y-4">
              <AdaptiveToggle />
              <Toggle
                label="Let this browser be played to"
                hint={`It checks every couple of seconds while Stream is open. ${current.browser}.`}
                checked={current.remote_control}
                onChange={(remote_control) => save.mutate({ remote_control })}
                disabled={save.isPending}
              />
              <form
                className="flex items-end gap-2"
                onSubmit={(event) => {
                  event.preventDefault();
                  save.mutate({ label: draft.value("label") });
                }}
              >
                <div className="flex-1">
                  <Input label="Its name" placeholder="Living room" value={draft.value("label")} onChange={(event) => draft.set("label", event.target.value)} />
                </div>
                <Button type="submit" variant="secondary" disabled={save.isPending}>
                  Save
                </Button>
              </form>
              <FormError message={save.errorMessage} />
            </div>
          )}
        </QueryState>
      </CardBody>
    </Card>
  );
}

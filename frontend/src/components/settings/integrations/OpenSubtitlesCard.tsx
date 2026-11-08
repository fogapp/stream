import { api } from "@/api/client";
import { useConnectionSettings } from "@/hooks/useConnectionSettings";
import { useDraft } from "@/hooks/useDraft";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { ConnectionCard } from "@/components/settings/ConnectionCard";
import { ConnectionTestLine } from "@/components/settings/TestResultLine";
import { CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { MutationForm } from "@/components/ui/MutationForm";
import { QueryState } from "@/components/ui/PageState";
import { SecretInput } from "@/components/ui/SecretInput";
import { Toggle } from "@/components/ui/Toggle";
import type { OpenSubtitlesSettings } from "@/types";

/** OpenSubtitles: missing subtitle languages for movies and episodes (PROPOSAL §5.5). */
export function OpenSubtitlesCard() {
  const { settings, test, current, saved, patch } = useConnectionSettings<OpenSubtitlesSettings>("/open_subtitles_setting", keys.openSubtitles);
  // Languages are edited as one comma-separated field.
  const draft = useDraft(current && { username: current.username, languages: current.languages.join(", ") }, {
    api_key: "",
    username: "",
    password: "",
    languages: "en",
  });
  const save = useFormMutation({
    mutationFn: () => {
      const { languages, ...rest } = draft.values();
      return api.patch<OpenSubtitlesSettings>("/open_subtitles_setting", {
        open_subtitles_setting: { ...rest, languages: languages.split(",").map((code) => code.trim()) },
      });
    },
    onSuccess: (data) => {
      draft.reset();
      saved(data);
    },
    fallback: "Could not save OpenSubtitles' settings",
  });

  return (
    <ConnectionCard
      title="OpenSubtitles"
      setUp={current !== null}
      enabled={current?.enabled}
      test={current ? test : null}
      description="Fetches a movie's or episode's missing subtitle languages — the same file's first — and keeps them. Optional."
    >
      <CardBody className="space-y-4">
        {current ? (
          <>
            <ConnectionTestLine test={test} stored={current} />
            <Toggle label="Fetch missing subtitles" checked={current.enabled} onChange={(enabled) => patch({ open_subtitles_setting: { enabled } })} />
            {current.remaining_downloads !== null ? (
              <p className="text-sm text-muted">{current.remaining_downloads} downloads left today.</p>
            ) : null}
          </>
        ) : null}
        <QueryState query={settings} errorMessage="Could not load OpenSubtitles' settings.">
          {() => (
            <MutationForm mutation={save} label="Save" disabled={!current && !draft.value("api_key").trim()}>
              <SecretInput
                label="API key"
                value={draft.value("api_key")}
                onChange={(event) => draft.set("api_key", event.target.value)}
                saved={current !== null}
                placeholder="From opensubtitles.com › API consumers"
              />
              <div className="grid gap-4 sm:grid-cols-2">
                <Input
                  label="Username"
                  value={draft.value("username")}
                  onChange={(event) => draft.set("username", event.target.value)}
                  hint="Optional: more downloads a day."
                />
                <Input
                  label="Password"
                  type="password"
                  autoComplete="off"
                  value={draft.value("password")}
                  onChange={(event) => draft.set("password", event.target.value)}
                />
              </div>
              <Input
                label="Languages"
                value={draft.value("languages")}
                onChange={(event) => draft.set("languages", event.target.value)}
                hint="Two-letter codes, separated by commas, e.g. en, fr"
              />
            </MutationForm>
          )}
        </QueryState>
      </CardBody>
    </ConnectionCard>
  );
}

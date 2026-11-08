import { api } from "@/api/client";
import { useConnectionSettings } from "@/hooks/useConnectionSettings";
import { useDraft } from "@/hooks/useDraft";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { WHISPER_API_KIND_OPTIONS } from "@/lib/whisper";
import { ConnectionCard } from "@/components/settings/ConnectionCard";
import { ConnectionTestLine } from "@/components/settings/TestResultLine";
import { CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { MutationForm } from "@/components/ui/MutationForm";
import { QueryState } from "@/components/ui/PageState";
import { SecretInput } from "@/components/ui/SecretInput";
import { Select } from "@/components/ui/Select";
import { Toggle } from "@/components/ui/Toggle";
import { WHISPER_API_KINDS, type WhisperApiKind, type WhisperSettings } from "@/types";

/** Whisper: speech to text for channel videos without subtitles (PROPOSAL §5.5). */
export function WhisperCard() {
  const { settings, test, current, saved, patch } = useConnectionSettings<WhisperSettings>("/whisper_setting", keys.whisper);
  const draft = useDraft<{ url: string; api_kind: WhisperApiKind; model: string; api_key: string }>(current, {
    url: "",
    api_kind: "asr_webservice",
    model: "",
    api_key: "",
  });
  const save = useFormMutation({
    mutationFn: () => api.patch<WhisperSettings>("/whisper_setting", { whisper_setting: draft.values() }),
    onSuccess: (data) => {
      draft.reset();
      saved(data);
    },
    fallback: "Could not save Whisper's settings",
  });
  const kind = draft.value("api_kind");

  return (
    <ConnectionCard
      title="Whisper"
      setUp={current !== null}
      enabled={current?.enabled}
      test={current ? test : null}
      description="Transcribes channel videos that have no subtitles, so what they say can be searched and captioned. Optional."
    >
      <CardBody className="space-y-4">
        {current ? (
          <>
            <ConnectionTestLine test={test} stored={current} />
            <Toggle label="Transcribe new videos" checked={current.enabled} onChange={(enabled) => patch({ whisper_setting: { enabled } })} />
          </>
        ) : null}
        <QueryState query={settings} errorMessage="Could not load Whisper's settings.">
          {() => (
            <MutationForm mutation={save} label="Save">
              <Input
                label="Address"
                value={draft.value("url")}
                onChange={(event) => draft.set("url", event.target.value)}
                placeholder="http://whisper:9000"
                hint="fog's Whisper app answers on port 9000."
              />
              <Select label="Kind of server" value={kind} onChange={(event) => draft.set("api_kind", event.target.value as WhisperApiKind)}>
                {WHISPER_API_KINDS.map((option) => (
                  <option key={option} value={option}>
                    {WHISPER_API_KIND_OPTIONS[option].label}
                  </option>
                ))}
              </Select>
              {kind === "openai" ? (
                <>
                  <Input label="Model" value={draft.value("model")} onChange={(event) => draft.set("model", event.target.value)} placeholder="whisper-1" />
                  <SecretInput
                    label="API key"
                    value={draft.value("api_key")}
                    onChange={(event) => draft.set("api_key", event.target.value)}
                    saved={Boolean(current?.api_key_set)}
                    placeholder="If the server needs one"
                  />
                </>
              ) : null}
            </MutationForm>
          )}
        </QueryState>
      </CardBody>
    </ConnectionCard>
  );
}

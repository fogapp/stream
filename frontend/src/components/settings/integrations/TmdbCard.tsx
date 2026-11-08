import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { api } from "@/api/client";
import { useAuth } from "@/hooks/useAuth";
import { useConnectionSettings } from "@/hooks/useConnectionSettings";
import { useFormMutation } from "@/hooks/useFormMutation";
import type { useTestConnection } from "@/hooks/useTestConnection";
import { keys } from "@/lib/queryKeys";
import { ConnectionCard } from "@/components/settings/ConnectionCard";
import { ConnectionTestLine } from "@/components/settings/TestResultLine";
import { CardBody } from "@/components/ui/Card";
import { MutationForm } from "@/components/ui/MutationForm";
import { QueryState } from "@/components/ui/PageState";
import { SecretInput } from "@/components/ui/SecretInput";
import type { TmdbSettings } from "@/types";

/** TMDB: titles and artwork. Everyone sees whether it's connected; an admin sets the key. */
export function TmdbCard() {
  const { settings, test } = useConnectionSettings<TmdbSettings>("/tmdb_setting", keys.tmdb);
  return (
    <QueryState query={settings} errorMessage="Could not load integrations.">
      {(tmdb) => <TmdbForm settings={tmdb} test={test} />}
    </QueryState>
  );
}

function TmdbForm({ settings, test }: { settings: TmdbSettings; test: ReturnType<typeof useTestConnection> }) {
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const admin = user?.role === "admin";
  const [key, setKey] = useState("");
  const save = useFormMutation({
    mutationFn: () => api.patch<TmdbSettings>("/tmdb_setting", { tmdb_setting: { api_key: key } }),
    onSuccess: () => {
      setKey("");
      queryClient.invalidateQueries({ queryKey: keys.tmdb.all });
    },
    fallback: "Could not save the key",
  });

  return (
    <ConnectionCard
      title="TMDB"
      setUp={settings.configured}
      badge="Connected"
      test={admin && settings.configured ? test : null}
      description="Titles, artwork, cast and episode lists. Without a key, files still play under their file names."
    >
      <CardBody className="space-y-4">
        <ConnectionTestLine test={test} stored={settings} />
        {admin ? (
          <MutationForm mutation={save} label="Save key" disabled={!key.trim()}>
            <SecretInput
              label={settings.configured ? "Replace the key" : "API key or read access token"}
              value={key}
              onChange={(event) => setKey(event.target.value)}
              saved={settings.configured}
              placeholder="From themoviedb.org › Settings › API"
              hint="Either TMDB credential works. Adding the first key re-matches everything filed so far."
            />
          </MutationForm>
        ) : null}
      </CardBody>
    </ConnectionCard>
  );
}

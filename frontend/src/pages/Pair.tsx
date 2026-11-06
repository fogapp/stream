import { useState } from "react";
import { useSearchParams } from "react-router-dom";
import { api } from "@/api/client";
import { useFormMutation } from "@/hooks/useFormMutation";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/Button";
import { FormError } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";

/** Where a TV's code is entered, by someone signed in (PROPOSAL §7.4). The
 *  TV's QR code opens /pair?code=…, filled in but still waiting for a tap. */
export function Pair() {
  const [params] = useSearchParams();
  const [code, setCode] = useState(() => (params.get("code") ?? "").toUpperCase());
  const approve = useFormMutation({
    fallback: "That code didn't work.",
    mutationFn: () => api.post<{ device: string }>("/pairings/approve", { code }),
  });
  return (
    <div className="space-y-6 px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
      <PageHeader title="Sign in a TV" description="Enter the code your TV is showing. It signs in as you." />
      {approve.data ? (
        <p className="text-lg text-positive">Done — the TV ({approve.data.device}) is signing in.</p>
      ) : (
        <form
          className="flex max-w-md items-end gap-2"
          onSubmit={(event) => {
            event.preventDefault();
            approve.mutate();
          }}
        >
          <div className="flex-1">
            <Input label="Code" value={code} onChange={(event) => setCode(event.target.value.toUpperCase())} placeholder="ABCD-EFGH" autoComplete="off" autoFocus />
          </div>
          <Button type="submit" disabled={code.replace(/[^A-Z0-9]/g, "").length < 8 || approve.isPending}>
            Sign in the TV
          </Button>
        </form>
      )}
      <FormError message={approve.errorMessage} />
    </div>
  );
}

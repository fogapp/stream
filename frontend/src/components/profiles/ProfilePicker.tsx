import { useEffect, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Delete, Lock } from "lucide-react";
import { api, apiErrorMessage } from "@/api/client";
import { profilesQuery } from "@/lib/queries";
import { ProfileAvatar } from "@/components/profiles/ProfileAvatar";
import { Button } from "@/components/ui/Button";
import { Checkbox } from "@/components/ui/Checkbox";
import { IconButton } from "@/components/ui/IconButton";
import { QueryState } from "@/components/ui/PageState";
import { BrandMark } from "@/components/layout/BrandMark";
import type { ProfileInfo } from "@/types";

/**
 * "Who's watching?" (PROPOSAL §7.4): big enough for a TV across the room.
 * A PIN'd profile asks for its PIN; any choice can become this device's
 * default, so next time there's no asking at all.
 */
export function ProfilePicker({ onChosen, onCancel }: { onChosen: (token: string) => void; onCancel?: () => void }) {
  const profiles = useQuery(profilesQuery());
  const [pending, setPending] = useState<ProfileInfo | null>(null);
  const [pin, setPin] = useState("");
  const [makeDefault, setMakeDefault] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const choose = async (profile: ProfileInfo, withPin?: string) => {
    setBusy(true);
    setError(null);
    try {
      const result = await api.post<{ token: string }>(`/profiles/${profile.id}/select`, { pin: withPin, make_default: makeDefault });
      onChosen(result.token);
    } catch (failure) {
      setError(apiErrorMessage(failure, "That didn't work."));
      setPin("");
    } finally {
      setBusy(false);
    }
  };

  const press = (digit: string) => {
    if (!pending || busy) return;
    setPin((value) => `${value}${digit}`.slice(0, 8));
  };

  const form = useRef<HTMLFormElement>(null);
  // A keyboard (or a TV remote's number keys) types the PIN wherever focus is.
  useEffect(() => {
    if (!pending) return;
    const onKey = (event: KeyboardEvent) => {
      if (/^\d$/.test(event.key)) setPin((value) => `${value}${event.key}`.slice(0, 8));
      else if (event.key === "Backspace") setPin((value) => value.slice(0, -1));
      else if (event.key === "Escape") setPending(null);
      else if (event.key === "Enter" && !(event.target instanceof HTMLButtonElement)) form.current?.requestSubmit();
      else return;
      event.preventDefault();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [pending]);

  return (
    <div data-theme="dark" className="fixed inset-0 z-[70] flex flex-col items-center justify-center gap-10 overflow-y-auto bg-background p-6 text-foreground">
      {pending ? (
        <div className="flex w-full max-w-xs flex-col items-center gap-6" role="dialog" aria-label={`PIN for ${pending.name}`}>
          <ProfileAvatar profile={pending} size="lg" />
          <p className="text-lg font-semibold">Enter {pending.name}&rsquo;s PIN</p>
          <div className="flex h-6 gap-3" aria-live="polite" aria-label={`${pin.length} digits entered`}>
            {Array.from({ length: Math.max(4, pin.length) }, (_, index) => (
              <span key={index} className={index < pin.length ? "h-3 w-3 rounded-full bg-foreground" : "h-3 w-3 rounded-full bg-foreground/25"} />
            ))}
          </div>
          <form
            ref={form}
            className="grid grid-cols-3 gap-3"
            onSubmit={(event) => {
              event.preventDefault();
              if (pin.length >= 4) void choose(pending, pin);
            }}
          >
            {["1", "2", "3", "4", "5", "6", "7", "8", "9"].map((digit) => (
              <Button key={digit} type="button" variant="secondary" size="lg" className="h-14 w-14 text-xl" onClick={() => press(digit)}>
                {digit}
              </Button>
            ))}
            <Button type="button" variant="ghost" size="lg" className="h-14 w-14" onClick={() => setPending(null)}>
              Back
            </Button>
            <Button type="button" variant="secondary" size="lg" className="h-14 w-14 text-xl" onClick={() => press("0")}>
              0
            </Button>
            <IconButton label="Delete a digit" size="lg" className="h-14 w-14" onClick={() => setPin((value) => value.slice(0, -1))}>
              <Delete className="h-5 w-5" aria-hidden />
            </IconButton>
            <Button type="submit" className="col-span-3" disabled={pin.length < 4 || busy}>
              {busy ? "Checking…" : "OK"}
            </Button>
          </form>
          {error ? <p role="alert" className="text-sm text-negative">{error}</p> : null}
        </div>
      ) : (
        <>
          <BrandMark className="h-14 w-14" />
          <h1 className="text-3xl font-bold tracking-tight sm:text-4xl">Who&rsquo;s watching?</h1>
          <QueryState query={profiles} errorMessage="Could not load profiles.">
            {(list) => (
              <ul className="flex max-w-4xl flex-wrap justify-center gap-6 sm:gap-10">
                {list.map((profile) => (
                  <li key={profile.id}>
                    <button
                      type="button"
                      disabled={busy}
                      onClick={() => {
                        setError(null);
                        if (profile.has_pin) {
                          setPin("");
                          setPending(profile);
                        } else void choose(profile);
                      }}
                      className="group flex w-28 flex-col items-center gap-3 rounded-[var(--radius-card)] p-2 sm:w-32"
                    >
                      <ProfileAvatar profile={profile} size="lg" className="transition group-hover:scale-105 group-focus-visible:scale-105" />
                      <span className="flex items-center gap-1 text-base text-muted group-hover:text-foreground">
                        {profile.name}
                        {profile.has_pin ? <Lock className="h-3.5 w-3.5" aria-label="PIN" /> : null}
                      </span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </QueryState>
          <div className="flex flex-col items-center gap-3">
            <Checkbox label="Always use this profile on this device" checked={makeDefault} onChange={setMakeDefault} />
            {error ? <p role="alert" className="text-sm text-negative">{error}</p> : null}
            {onCancel ? (
              <Button variant="ghost" onClick={onCancel}>
                Cancel
              </Button>
            ) : null}
          </div>
        </>
      )}
    </div>
  );
}

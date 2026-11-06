import { useEffect, useRef, useState, type FormEvent } from "react";
import { Navigate, useLocation } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { api, ApiError, apiErrorMessage } from "@/api/client";
import { loginWithPasskey, passkeyErrorMessage, passkeysSupported } from "@/lib/passkeys";
import { keys } from "@/lib/queryKeys";
import { useAuth } from "@/hooks/useAuth";
import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Checkbox } from "@/components/ui/Checkbox";
import { FormError } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { BrandMark } from "@/components/layout/BrandMark";
import type { SessionResponse, SetupStatus } from "@/types";

/** What a refused fog sign-in says (/login#signin_error=…): fog's own
 *  refusal, and the kit's VISITOR_REFUSALS for people from other households. */
const SIGNIN_ERRORS: Record<string, string> = {
  access_denied: "fog didn't let you in. Ask whoever runs it to share Stream with you.",
  visitors_not_hosted: "Stream doesn't let people from other households in.",
  visitor_mismatch: "This sign-in doesn't match the account it's linked to.",
  not_set_up: "Stream isn't set up yet; someone in its household has to sign in first.",
};

/** Login doubles as the first-run wizard: a fresh fog deploy has no users, so
 *  the same screen creates the household and its first admin — or restores a
 *  fog-backup/1 artifact and recovers the previous instance instead. */
export function Login() {
  const { signIn, completeSetup, adoptSession, isAuthenticated } = useAuth();
  const from = (useLocation().state as { from?: string } | null)?.from;
  const { data: setup } = useQuery({
    queryKey: keys.session.setup(),
    queryFn: ({ signal }) => api.get<SetupStatus>("/setup", { signal }),
  });

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [name, setName] = useState("");
  const [householdName, setHouseholdName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const [mode, setMode] = useState<"create" | "restore">("create");
  // Signing in, or joining with an invite code an admin made in Settings › Users.
  const [joining, setJoining] = useState(false);
  const [inviteCode, setInviteCode] = useState("");
  const [confirmIdentity, setConfirmIdentity] = useState(false);
  const [needsIdentityConfirm, setNeedsIdentityConfirm] = useState(false);
  const [restarting, setRestarting] = useState(false);
  const fileRef = useRef<HTMLInputElement>(null);

  const isSetup = setup?.setup_required === true;
  const fogSignin = setup?.signin?.enabled === true;
  const fogOnly = setup?.signin?.fog_only === true;
  // A sign-in that came back refused or broken says so here (the callback
  // puts the reason in the fragment).
  const [signinError] = useState(() => new URLSearchParams(window.location.hash.slice(1)).get("signin_error"));
  const canPasskey = passkeysSupported();

  // The WebAuthn ceremony runs in the browser; the server hands back the
  // same session shape as a password sign-in.
  async function onPasskey() {
    setError(null);
    setBusy(true);
    try {
      adoptSession(await loginWithPasskey(email.trim() || undefined));
    } catch (caught) {
      setError(apiErrorMessage(caught, passkeyErrorMessage(caught)));
    } finally {
      setBusy(false);
    }
  }

  // After the restore is armed the app restarts itself; poll until it's back
  // and recovered (setup no longer required), then reload into the login of
  // the restored instance.
  useEffect(() => {
    if (!restarting) return;
    const timer = setInterval(async () => {
      try {
        const status = await api.get<SetupStatus>("/setup");
        if (!status.setup_required) window.location.reload();
      } catch {
        // Still restarting/restoring — keep waiting.
      }
    }, 5000);
    return () => clearInterval(timer);
  }, [restarting]);

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    setBusy(true);
    try {
      if (isSetup && mode === "restore") {
        const file = fileRef.current?.files?.[0];
        if (!file) {
          setError("Choose a backup artifact (.fogpack.tar) first");
          return;
        }
        const form = new FormData();
        form.append("artifact", file);
        if (confirmIdentity) form.append("confirm_identity", "true");
        await api.postForm("/setup/restore", form);
        setRestarting(true);
      } else if (isSetup) {
        await completeSetup({ household_name: householdName, email, name, password });
      } else if (joining) {
        adoptSession(await api.post<SessionResponse>("/invites/accept", { code: inviteCode.trim(), name, email, password }));
      } else {
        await signIn(email, password);
      }
    } catch (caught) {
      setError(apiErrorMessage(caught, "Something went wrong"));
      // Identity drift is refused until explicitly confirmed — surface the
      // checkbox only once the server has said that's the blocker.
      if (caught instanceof ApiError && caught.errors.join(" ").includes("confirm_identity")) setNeedsIdentityConfirm(true);
    } finally {
      setBusy(false);
    }
  }

  // A successful sign-in (form, passkey, or first-run setup) sets the user;
  // nothing else moves off /login, so this is where the redirect lives —
  // back to wherever a signed-out visit was headed.
  if (isAuthenticated) return <Navigate to={from?.startsWith("/") ? from : "/"} replace />;

  if (restarting) {
    return (
      <div className="flex min-h-screen items-center justify-center px-4">
        <Card className="w-full max-w-sm">
          <CardBody>
            <h1 className="text-xl font-semibold text-foreground">Restoring…</h1>
            <p className="mt-2 text-sm text-muted">
              The artifact is armed and the app is restarting to recover. Large
              archives can take a few minutes — this page will reload when the
              restored instance is back.
            </p>
          </CardBody>
        </Card>
      </div>
    );
  }

  return (
    <div className="flex min-h-screen items-center justify-center px-4">
      <Card className="w-full max-w-sm">
        <CardBody>
          <div className="mb-6">
            <BrandMark className="mb-4 h-12 w-12" />
            <h1 className="text-xl font-semibold text-foreground">
              {isSetup ? "Set up Stream" : "Stream"}
            </h1>
            <p className="mt-1 text-sm text-muted">
              {isSetup
                ? mode === "restore"
                  ? "Recover a previous instance from a backup artifact."
                  : "Create your household and the first admin account."
                : joining
                  ? "Join the household with the invite code you were given."
                  : "Sign in to the curation console."}
            </p>
          </div>

          {fogSignin ? (
            <div className={fogOnly ? "" : "mb-6"}>
              <Button
                type="button"
                className="w-full"
                onClick={() => {
                  const to = from?.startsWith("/") && !from.startsWith("//") ? from : "/";
                  window.location.href = `/auth/oidc/start?${new URLSearchParams({ return_to: to })}`;
                }}
              >
                Sign in with fog
              </Button>
              {signinError ? (
                <FormError
                  className="mt-3"
                  message={SIGNIN_ERRORS[signinError] ?? "Signing in with fog didn't work. Try again."}
                />
              ) : null}
              {fogOnly ? (
                <p className="mt-3 text-xs text-muted">Stream signs everyone in with fog.</p>
              ) : (
                <p className="mt-3 text-center text-xs text-muted">or</p>
              )}
            </div>
          ) : null}

          {isSetup && !fogOnly ? (
            <div className="mb-4 flex gap-2">
              <Button
                type="button"
                size="sm"
                variant={mode === "create" ? "primary" : "secondary"}
                onClick={() => setMode("create")}
              >
                Start fresh
              </Button>
              <Button
                type="button"
                size="sm"
                variant={mode === "restore" ? "primary" : "secondary"}
                onClick={() => setMode("restore")}
              >
                Restore from backup
              </Button>
            </div>
          ) : null}

          {fogOnly ? null : (
            <form onSubmit={onSubmit} className="space-y-4">
              {isSetup && mode === "restore" ? (
                <>
                  <div>
                    <label className="mb-1 block text-sm font-medium text-foreground" htmlFor="artifact">
                      Backup artifact
                    </label>
                    <input
                      ref={fileRef}
                      id="artifact"
                      name="artifact"
                      type="file"
                      accept=".tar,application/x-tar"
                      className="block w-full text-sm text-foreground file:mr-3 file:rounded-[var(--radius-control)] file:border file:border-border file:bg-surface file:px-3 file:py-1.5 file:text-sm file:text-foreground"
                    />
                    <p className="mt-1 text-xs text-muted">
                      A .fogpack.tar produced by this app (fog keeps them under Backups).
                    </p>
                  </div>
                  {needsIdentityConfirm ? (
                    <Checkbox
                      checked={confirmIdentity}
                      onChange={setConfirmIdentity}
                      label="The artifact was made for a different host. I understand a host change breaks every passkey and stored peer connection — restore anyway."
                    />
                  ) : null}
                </>
              ) : (
                <>
                  {joining ? (
                    <>
                      <Input
                        label="Invite code"
                        name="invite_code"
                        autoComplete="off"
                        value={inviteCode}
                        onChange={(e) => setInviteCode(e.target.value)}
                        required
                      />
                      <Input label="Your name" name="name" value={name} onChange={(e) => setName(e.target.value)} required />
                    </>
                  ) : null}
                  {isSetup ? (
                    <>
                      <Input
                        label="Household name"
                        name="household_name"
                        value={householdName}
                        onChange={(e) => setHouseholdName(e.target.value)}
                        required
                      />
                      <Input
                        label="Your name"
                        name="name"
                        value={name}
                        onChange={(e) => setName(e.target.value)}
                        required
                      />
                    </>
                  ) : null}
                  <Input
                    label="Email"
                    name="email"
                    type="email"
                    autoComplete="username"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    required
                  />
                  <Input
                    label="Password"
                    name="password"
                    type="password"
                    autoComplete={isSetup || joining ? "new-password" : "current-password"}
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    hint={isSetup || joining ? "At least 10 characters." : undefined}
                    required
                  />
                </>
              )}
              <FormError message={error} />
              <Button type="submit" className="w-full" disabled={busy}>
                {busy
                  ? "Working…"
                  : isSetup
                    ? mode === "restore"
                      ? "Restore"
                      : "Create household"
                    : joining
                      ? "Join"
                      : "Sign in"}
              </Button>
              {!isSetup && canPasskey && !joining ? (
                <Button type="button" variant="secondary" className="w-full" disabled={busy} onClick={onPasskey}>
                  Sign in with a passkey
                </Button>
              ) : null}
              {!isSetup ? (
                <Button
                  type="button"
                  variant="ghost"
                  className="w-full"
                  disabled={busy}
                  onClick={() => {
                    setJoining((current) => !current);
                    setError(null);
                  }}
                >
                  {joining ? "I already have an account" : "Have an invite code?"}
                </Button>
              ) : null}
            </form>
          )}
        </CardBody>
      </Card>
    </div>
  );
}

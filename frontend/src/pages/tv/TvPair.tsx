import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { api, ApiError } from "@/api/client";
import { useAuth } from "@/hooks/useAuth";
import type { SessionResponse } from "@/types";

interface Started {
  code: string;
  poll_token: string;
  expires_at: string;
}

/**
 * A TV signs in without a keyboard (PROPOSAL §7.4): it shows a code, and
 * someone already signed in enters it at /pair on their phone.
 */
export function TvPair() {
  const navigate = useNavigate();
  const { adoptSession } = useAuth();
  const [started, setStarted] = useState<Started | null>(null);
  const [problem, setProblem] = useState<string | null>(null);

  useEffect(() => {
    if (started) return;
    let live = true;
    api
      .post<Started>("/pairings")
      .then((result) => live && setStarted(result))
      .catch((error: unknown) => live && setProblem(error instanceof ApiError ? error.message : "Couldn't reach Stream."));
    return () => {
      live = false;
    };
  }, [started]);

  useEffect(() => {
    if (!started) return;
    const timer = window.setInterval(() => {
      api
        .get<{ state: "pending" } | ({ state: "approved" } & SessionResponse)>(`/pairings/${started.poll_token}`)
        .then((result) => {
          if (result.state !== "approved") return;
          window.clearInterval(timer);
          adoptSession({ token: result.token, user: result.user });
          navigate("/tv", { replace: true });
        })
        .catch(() => {
          // Expired: start again with a fresh code.
          window.clearInterval(timer);
          setStarted(null);
        });
    }, 3000);
    return () => window.clearInterval(timer);
  }, [started, adoptSession, navigate]);

  return (
    <div data-theme="dark" className="flex min-h-dvh flex-col items-center justify-center gap-10 bg-background p-12 text-center text-foreground">
      <h1 className="text-5xl font-bold tracking-tight">Sign in to Stream</h1>
      {problem ? (
        <p className="text-2xl text-negative">{problem}</p>
      ) : started ? (
        <>
          <p className="text-2xl text-muted">
            On your phone or computer, open <span className="font-semibold text-foreground">{window.location.host}/pair</span> and enter
          </p>
          <p className="font-mono text-7xl font-bold tracking-[0.2em]" aria-label={`Code ${started.code.split("").join(" ")}`}>
            {started.code}
          </p>
          <p className="text-xl text-muted">This code works for ten minutes.</p>
        </>
      ) : (
        <p className="text-2xl text-muted">Getting a code…</p>
      )}
    </div>
  );
}

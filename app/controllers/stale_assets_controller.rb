# typed: strict
# frozen_string_literal: true

# Answers a request for a bundle this build doesn't have. Before
# StaticCacheControl, `/` went out with a one-year header, so a browser can
# still hold an index.html naming the entry script of an older image — it
# never asks the server for the page again, only for that script. A 404
# leaves #root empty; this script refetches the page past the HTTP cache and
# reloads once. It also catches a lazy chunk that vanished while a tab was
# open. ActionDispatch::Static serves every file that exists, so only
# missing ones get here.
class StaleAssetsController < ActionController::Base
  extend T::Sig

  # A GET answered with JavaScript trips the cross-origin <script> check.
  skip_forgery_protection

  RECOVERY_JS = <<~JS
    (async () => {
      const KEY = "stream-stale-html-recovery-at";
      try {
        // At most once a minute, so a genuinely broken deploy can't loop.
        if (Date.now() - Number(sessionStorage.getItem(KEY) || 0) < 60000) return;
        sessionStorage.setItem(KEY, String(Date.now()));
      } catch {}
      for (const path of new Set(["/", location.pathname])) {
        try { await fetch(path, { cache: "reload", credentials: "same-origin" }); } catch {}
      }
      location.reload();
    })();
  JS

  sig { void }
  def show
    # no-store also keeps the service worker from filing it under the old name.
    response.headers["Cache-Control"] = "no-store"
    # 200 and text/javascript: a module script won't run from a 404.
    render js: RECOVERY_JS
  end
end

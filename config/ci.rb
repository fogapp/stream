# typed: false

# Run using bin/ci — the local mirror of the deploy gate. A push to main is a
# production deploy (manor's doctrine), so this must be green before pushing.

CI.run do
  # Cheapest check we have, and it catches the one class of bug every other
  # check misses: files that exist locally but were never committed.
  step "Build inputs: tracked", "bin/check-tracked"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"

  # A gate that silently skips is worse than no gate: a checkout without RBIs
  # or node_modules would report green while typecheck and the design guard
  # never ran. Fail with instructions instead.
  step "Types: Sorbet",
    File.directory?("sorbet/rbi") ? "bundle exec srb tc" : "echo 'sorbet/rbi missing — run bin/tapioca gem' && false"

  step "Tests: RSpec", "bundle exec rspec --format progress"
  step "API: OpenAPI document current", "bin/check-openapi"

  step "Frontend: install check",
    File.directory?("frontend/node_modules") ? "true" : "echo 'frontend/node_modules missing — run npm --prefix frontend ci' && false"
  step "Frontend: lint", "npm --prefix frontend run lint"
  step "Frontend: typecheck + build", "npm --prefix frontend run build"
  step "Frontend: tests", "npm --prefix frontend test -- --run"
  step "Frontend: design guard", "bin/design-guard"

  # The browser harness (frontend/e2e): SPA, API, jobs and a real transcoder
  # together over real media — the only check that proves a title plays,
  # seeks and resumes. It needs the dev Postgres (docker compose up -d db,
  # migrated), ffmpeg 7+, Google Chrome, and Playwright's browsers
  # (npx --prefix frontend playwright install chromium webkit); missing any,
  # it fails saying which.
  step "E2E: Playwright", "npm --prefix frontend run e2e"
end

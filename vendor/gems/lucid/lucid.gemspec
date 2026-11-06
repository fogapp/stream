# frozen_string_literal: true

require_relative "lib/lucid/version"

Gem::Specification.new do |s|
  s.name        = "lucid"
  s.version     = Lucid::VERSION
  s.summary     = "Metrics, traces, profiles, logs and visitor analytics for Lucid"
  s.description = "The Lucid agent for Rails apps: auto-instruments requests, SQL, jobs and the runtime, " \
                  "profiles continuously, and ships everything to the LUCID_URL with the LUCID_API_KEY. " \
                  "Inert without both."
  s.authors     = ["Matthew Werner"]
  s.homepage    = "https://github.com/fogapp/fin/tree/main/vendor/gems/lucid"
  s.license     = "AGPL-3.0-only"
  s.files       = Dir["lib/**/*.rb", "lib/**/*.js", "README.md"]
  s.required_ruby_version = ">= 3.2.1"
  # One runtime dependency, on purpose (lucid:docs/PROPOSAL.md §7.1, D2): a
  # sampler written in Ruby can only observe a thread once it has released
  # the GVL, so it attributes nearly all time to blocking calls — measured,
  # 99% to `sleep` against a truth of 4%. Vernier samples natively, has no
  # dependencies of its own, and is loaded lazily: if it cannot be loaded the
  # agent runs without profiles rather than not at all.
  s.add_dependency "vernier", ">= 1.8"
  s.add_development_dependency "minitest", "~> 5.16"
  s.add_development_dependency "rake", "~> 13.0"
end

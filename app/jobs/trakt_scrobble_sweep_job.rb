# typed: strict
# frozen_string_literal: true

# Pauses on Trakt the plays whose players went quiet (PROPOSAL §7.4): the
# players never say "paused", they just stop reporting. Fans out only.
class TraktScrobbleSweepJob < ApplicationJob
  extend T::Sig

  JOB_KEY = "trakt_scrobble_sweep"

  queue_as :control
  limits_concurrency to: 1, key: -> { JOB_KEY }

  sig { void }
  def perform
    Trakt::Scrobbler.sweep
  end
end

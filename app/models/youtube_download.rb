# typed: strict
# frozen_string_literal: true

# One video Stream means to fetch from YouTube (PROPOSAL §5.4), and how it
# went. The row outlives the file: "removed" is what retention deleted, so
# a later poll never fetches it again. A `kept` row is one someone marked
# to keep, and the keep-last rule passes it by. A `by_hand` row is one
# someone asked for — pasted, or fetched again — and the channel's rules
# don't refuse it.
class YoutubeDownload < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  class State < T::Enum
    include ApplicationEnum
    enums do
      Queued = new("queued")
      Downloading = new("downloading")
      Done = new("done")
      # Refused by a rule (a Short, a livestream, too old): not an error.
      Skipped = new("skipped")
      Failed = new("failed")
      # Deleted by the channel's keep-last rule.
      Removed = new("removed")
    end
  end

  MAX_ATTEMPTS = 3

  belongs_to :channel

  attribute :state, State

  # Not while it's on its way.
  sig { returns(T::Boolean) }
  def can_fetch_again? = ![ State::Queued, State::Downloading ].include?(state_enum)

  # Someone asked for it again: queued afresh, over the file already there,
  # whatever the channel's rules say.
  sig { params(kept: T::Boolean).void }
  def fetch_again!(kept: self.kept)
    update!(state: State::Queued.serialize, attempts: 0, last_error: nil, reason: nil, by_hand: true, kept: kept)
    DownloadVideoJob.perform_later(id)
  end
end

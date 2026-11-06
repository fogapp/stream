# typed: strict
# frozen_string_literal: true

# The household's MLB.tv account (PROPOSAL §7.8): what yt-dlp signs in with
# to find a game's broadcasts. The password is write-only, and goes to
# yt-dlp in a netrc file, never on its command line. Saving one is what
# puts Baseball in the sidebar.
class MlbSetting < ApplicationRecord
  extend T::Sig
  include HouseholdScoped
  include ConnectionTested

  encrypts :password

  # Its clubs' streams, for the Grid's editor (Mlb::TeamStreams).
  after_create_commit { EnsureMlbTeamStreamsJob.perform_later(T.bind(self, MlbSetting).household_id) }

  normalizes :username, with: ->(username) { username.strip }

  validates :username, presence: true, length: { maximum: 200 }
  validates :password, presence: true, length: { maximum: 200 }
  # A netrc file is whitespace-separated words: either can't hold a line
  # break, and the quotes and backslashes a password may have are escaped.
  validates :username, format: { without: /\s/, message: "can't have spaces" }
  validates :password, format: { without: /[\r\n]/, message: "can't have line breaks" }
end

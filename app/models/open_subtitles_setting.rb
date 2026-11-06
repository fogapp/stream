# typed: strict
# frozen_string_literal: true

# The household's OpenSubtitles connection (PROPOSAL §5.5): an API key,
# optionally an account (more downloads a day), and the languages wanted.
class OpenSubtitlesSetting < ApplicationRecord
  extend T::Sig
  include HouseholdScoped
  include ConnectionTested

  encrypts :api_key
  encrypts :password

  normalizes :languages, with: ->(list) { Array(list).map { |code| code.to_s.strip.downcase }.grep(/\A[a-z]{2}(-[a-z]{2})?\z/).uniq.first(5) }

  validates :api_key, presence: true
  validates :languages, presence: true

  # Out of downloads until OpenSubtitles' day turns over.
  sig { returns(T::Boolean) }
  def exhausted?
    remaining = remaining_downloads
    resets = resets_at
    !remaining.nil? && remaining <= 0 && !resets.nil? && resets > Time.current
  end
end

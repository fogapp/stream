# typed: strict
# frozen_string_literal: true

module Playback
  # A session's decision as it was made and stored (Decision#to_h), read in
  # one place. Lenient on purpose: a row keeps whatever shape it was written
  # in, and what a session already answered with is its answer, so nothing
  # here decides anything again.
  class StoredDecision
    extend T::Sig

    sig { params(raw: T::Hash[String, T.untyped]).void }
    def initialize(raw)
      @raw = raw
    end

    sig { returns(T.nilable(String)) }
    def summary = @raw["summary"]

    sig { returns(T::Array[String]) }
    def reasons = Array(@raw["reasons"])

    sig { returns(T.nilable(T::Hash[String, T.untyped])) }
    def video = hash("video")

    sig { returns(T.nilable(T::Hash[String, T.untyped])) }
    def audio = hash("audio")

    # The picture copied as it is, not converted.
    sig { returns(T::Boolean) }
    def copy? = video&.fetch("copy", false) ? true : false

    sig { returns(T::Boolean) }
    def tonemap? = video&.fetch("tonemap", false) ? true : false

    # The picture subtitle drawn into the video, by stream index.
    sig { returns(T.nilable(Integer)) }
    def burned_subtitle = video&.fetch("burn_subtitle", nil)

    # The height it was converted to, when it was.
    sig { returns(T.nilable(Integer)) }
    def height = video&.fetch("height", nil)

    sig { returns(T.nilable(String)) }
    def audio_codec = audio&.fetch("codec", nil)&.to_s

    # A session from before this was stored can only have been asked for
    # again as a fallback, which never plays a file as-is but may play its
    # optimized version.
    sig { returns(T.nilable(String)) }
    def direct_mime_type = @raw["direct_mime_type"] || (@raw["method"] == "optimized" ? "video/mp4" : nil)

    sig { returns(T.nilable(String)) }
    def optimized_version_id = @raw["optimized_version_id"]&.to_s

    sig { returns(T.nilable(T::Hash[String, T.untyped])) }
    def capabilities = @raw["capabilities"]

    sig { returns(Constraints) }
    def constraints = Constraints.from_h(@raw["constraints"])

    # How it played, for telling whether another decision changes anything.
    sig { returns(T::Hash[String, T.untyped]) }
    def how_played = @raw.slice("method", "video", "audio")

    # Carried on from a session that failed (R2): what it fell from, and why.
    sig { returns(T.nilable(T::Hash[String, T.untyped])) }
    def fallback = hash("fallback")

    # Fell for a passing reason, so worth climbing back from.
    sig { returns(T::Boolean) }
    def transient_fallback? = fallback&.fetch("transient", nil) == true

    # An upgrade: a climb back up the ladder, and what it left.
    sig { returns(T::Boolean) }
    def upgrade? = @raw.key?("upgrade")

    # What the rung it climbed from was played under, when it climbed.
    sig { returns(T.nilable(Constraints)) }
    def upgraded_from
      upgraded = hash("upgrade")
      upgraded && Constraints.from_h(upgraded["constraints"])
    end

    private

    sig { params(key: String).returns(T.nilable(T::Hash[String, T.untyped])) }
    def hash(key)
      value = @raw[key]
      value.is_a?(Hash) ? value : nil
    end
  end
end

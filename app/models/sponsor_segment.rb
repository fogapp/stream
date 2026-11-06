# typed: strict
# frozen_string_literal: true

# One SponsorBlock segment of a video (PROPOSAL §5.4).
class SponsorSegment < ApplicationRecord
  extend T::Sig

  class Category < T::Enum
    include ApplicationEnum
    enums do
      Sponsor = new("sponsor")
      Selfpromo = new("selfpromo")
      Interaction = new("interaction")
      Intro = new("intro")
      Outro = new("outro")
      Preview = new("preview")
      Filler = new("filler")
      MusicOfftopic = new("music_offtopic")
    end
  end

  class Action < T::Enum
    include ApplicationEnum
    enums do
      Skip = new("skip")
      Ask = new("ask")
      Show = new("show")
    end
  end

  # What a profile gets until it says otherwise: sponsors go, the rest ask
  # or just show on the timeline.
  DEFAULT_ACTIONS = T.let({
    "sponsor" => "skip", "selfpromo" => "ask", "interaction" => "ask", "intro" => "ask", "outro" => "ask",
    "preview" => "ask", "filler" => "show", "music_offtopic" => "ask"
  }.freeze, T::Hash[String, String])

  belongs_to :video

  attribute :category, Category

  validates :end_seconds, comparison: { greater_than: :start_seconds }

  sig { params(profile: Profile).returns(T::Hash[String, String]) }
  def self.actions_for(profile)
    chosen = profile.sponsorblock.select { |category, action| DEFAULT_ACTIONS.key?(category) && Action.try_deserialize(action) }
    DEFAULT_ACTIONS.merge(chosen)
  end
end

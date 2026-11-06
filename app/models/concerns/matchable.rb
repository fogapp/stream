# typed: strict
# frozen_string_literal: true

# A title that a provider may or may not have recognized (PROPOSAL §5.2):
# movies and shows. The match state and its evidence live on the row, so the
# Needs match queue and the title page can say why without asking again.
module Matchable
  extend ActiveSupport::Concern
  extend T::Helpers
  include LockedFields
  include SortTitled

  requires_ancestor { ApplicationRecord }

  class State < T::Enum
    include ApplicationEnum
    enums do
      Matched = new("matched")
      # Candidates exist but none cleared the threshold; a person picks.
      NeedsReview = new("needs_review")
      # No provider configured, or no candidate at all.
      Unmatched = new("unmatched")
    end
  end

  included do
    T.bind(self, T.class_of(ApplicationRecord))

    attribute :match_state, State
    before_save { T.unsafe(self).rating_age = ContentRatings.age(T.unsafe(self).content_rating) }

    scope :needing_match, -> { where.not(match_state: State::Matched.serialize) }
  end
end

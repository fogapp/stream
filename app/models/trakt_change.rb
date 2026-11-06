# typed: strict
# frozen_string_literal: true

# One thing a linked profile did in Stream, waiting to be sent to Trakt
# (PROPOSAL §7.4). Rows leave when Trakt takes them; one Trakt refuses stays,
# with its error, until it has been tried MAX_ATTEMPTS times.
class TraktChange < ApplicationRecord
  extend T::Sig

  MAX_ATTEMPTS = 5

  class Action < T::Enum
    include ApplicationEnum
    enums do
      HistoryAdd = new("history_add")
      HistoryRemove = new("history_remove")
      RatingSet = new("rating_set")
      RatingRemove = new("rating_remove")
      WatchlistAdd = new("watchlist_add")
      WatchlistRemove = new("watchlist_remove")
    end

    # Only the latest of these counts for an item; history is every play.
    sig { returns(T::Boolean) }
    def last_wins?
      case self
      when HistoryAdd, HistoryRemove then false
      when RatingSet, RatingRemove, WatchlistAdd, WatchlistRemove then true
      else T.absurd(self)
      end
    end

    sig { returns(String) }
    def path
      case self
      when HistoryAdd then "/sync/history"
      when HistoryRemove then "/sync/history/remove"
      when RatingSet then "/sync/ratings"
      when RatingRemove then "/sync/ratings/remove"
      when WatchlistAdd then "/sync/watchlist"
      when WatchlistRemove then "/sync/watchlist/remove"
      else T.absurd(self)
      end
    end
  end

  attribute :action, Action

  belongs_to :trakt_account
  belongs_to :item, polymorphic: true

  scope :sendable, -> { where(attempts: ...MAX_ATTEMPTS) }
end

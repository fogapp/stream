# typed: strict
# frozen_string_literal: true

module Trakt
  # Where Stream's writers note what a linked profile did, for TraktPushJob
  # to send (PROPOSAL §7.4). A profile with no linked account, or a title
  # Trakt has no name for (a YouTube video, a home video, an unmatched
  # file), records nothing. What arrives from Trakt is written without
  # coming through here, so nothing echoes back.
  module Outbox
    extend T::Sig

    Action = TraktChange::Action

    # enqueue: false when many are being recorded at once (the first sync's
    # backfill), which queues the push itself when it's done — and hands
    # over the account it already has, rather than it being looked up again
    # for every row.
    sig do
      params(profile_id: T.nilable(String), action: Action, item: T.untyped, watched_at: T.nilable(ActiveSupport::TimeWithZone),
        rating: T.nilable(Integer), enqueue: T::Boolean, account: T.nilable(TraktAccount)).void
    end
    def self.record(profile_id, action, item, watched_at: nil, rating: nil, enqueue: true, account: nil)
      return unless item.is_a?(Movie) || item.is_a?(Episode) || item.is_a?(Show)

      account ||= TraktAccount.linked_for(profile_id)
      return if account.nil? || !Items.nameable?(item)

      TraktChange.create!(trakt_account: account, action: action.serialize, item: item, watched_at: watched_at, rating: rating,
        created_at: Time.current)
      TraktPushJob.perform_later(account.id) if enqueue
    end

    sig do
      params(profile_id: T.nilable(String), item: T.untyped, watched: T::Boolean, at: ActiveSupport::TimeWithZone, enqueue: T::Boolean,
        account: T.nilable(TraktAccount)).void
    end
    def self.watched(profile_id, item, watched:, at: Time.current, enqueue: true, account: nil)
      record(profile_id, watched ? Action::HistoryAdd : Action::HistoryRemove, item, watched_at: watched ? at : nil, enqueue: enqueue,
        account: account)
    end

    # Stream's stars go from 1 to 10 in halves; Trakt's are whole.
    sig do
      params(profile_id: T.nilable(String), item: T.untyped, value: T.nilable(Float), enqueue: T::Boolean, account: T.nilable(TraktAccount)).void
    end
    def self.rated(profile_id, item, value, enqueue: true, account: nil)
      if value.nil?
        record(profile_id, Action::RatingRemove, item, enqueue: enqueue, account: account)
      else
        record(profile_id, Action::RatingSet, item, rating: value.round.clamp(1, 10), enqueue: enqueue, account: account)
      end
    end

    sig { params(profile_id: T.nilable(String), item: T.untyped, saved: T::Boolean).void }
    def self.watch_later(profile_id, item, saved:)
      record(profile_id, saved ? Action::WatchlistAdd : Action::WatchlistRemove, item)
    end
  end
end

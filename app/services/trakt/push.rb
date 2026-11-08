# typed: strict
# frozen_string_literal: true

module Trakt
  # Sends a linked profile's waiting changes to Trakt (PROPOSAL §7.4), in
  # the order they happened: a run of the same action goes in one request.
  # Where only the latest counts (a rating, the watchlist), earlier changes
  # to the same title are dropped first.
  class Push
    extend T::Sig

    sig { params(account: TraktAccount).void }
    def initialize(account)
      @account = account
      @failed = T.let(0, Integer)
    end

    # Raises when Trakt can't be reached or asks to slow down, leaving the
    # rest waiting for the job's retry.
    sig { params(api: Api).returns(Integer) }
    def call(api = Api.for(@account))
      changes = collapse(@account.trakt_changes.sendable.order(:created_at, :id).includes(:item).to_a)
      sent = 0
      changes.chunk_while { |a, b| a.action_enum == b.action_enum }.each do |run|
        sent += deliver(api, run)
      end
      @account.update!(last_synced_at: Time.current, last_error: nil, last_error_at: nil) if sent.positive? && @failed.zero?
      sent
    end

    private

    sig { params(changes: T::Array[TraktChange]).returns(T::Array[TraktChange]) }
    def collapse(changes)
      latest = changes.select { |change| change.action_enum.last_wins? }
        .group_by { |change| [ change.action_enum.path.start_with?("/sync/watchlist"), change.item_type, change.item_id ] }
        .values.to_set(&:last)
      stale, kept = changes.partition { |change| change.action_enum.last_wins? && !latest.include?(change) }
      TraktChange.where(id: stale.map(&:id)).delete_all if stale.any?
      kept
    end

    sig { params(api: Api, run: T::Array[TraktChange]).returns(Integer) }
    def deliver(api, run)
      action = T.must(run.first).action_enum
      # A title deleted since, or matched to nothing Trakt knows.
      named, lost = run.partition { |change| Items.nameable?(change.item) }
      TraktChange.where(id: lost.map(&:id)).delete_all if lost.any?
      return 0 if named.empty?

      entries = named.map { |change| Items::Entry.new(item: change.item, watched_at: change.watched_at, rating: change.rating) }
      begin
        api.post(action.path, Items.body(entries))
      rescue Client::Error => e
        # A rate limit is Trakt being busy, not refusing these: the job's
        # retry sends them again rather than counting an attempt against them.
        raise if e.connection? || e.status.nil? || e.status.to_i >= 500 || e.is_a?(UpstreamHttpClient::RateLimitError)

        refused(named, e)
        return 0
      end
      TraktChange.where(id: named.map(&:id)).delete_all
      named.size
    end

    # Trakt refused these outright: say why, and try a few more times.
    sig { params(changes: T::Array[TraktChange], error: Client::Error).void }
    def refused(changes, error)
      message = error.status == 420 ? "Trakt's free accounts have a limit on lists and watchlist; this one is full." : error.message
      TraktChange.where(id: changes.map(&:id)).update_all([ "attempts = attempts + 1, last_error = ?", message.truncate(250) ]) # rubocop:disable Rails/SkipsModelValidations
      @account.record_error!("Couldn't send #{changes.size} change#{changes.size == 1 ? '' : 's'} to Trakt: #{message}")
      @failed += 1
    end
  end
end

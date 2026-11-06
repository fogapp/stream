# typed: strict
# frozen_string_literal: true

# The daily trailer pass (PROPOSAL §7.1–7.2): asks TMDB which trailer each
# matched title has when it was matched before trailers were kept, and tries
# again the ones that failed, a few times at most. Only fans out.
class FetchTrailersJob < ApplicationJob
  extend T::Sig

  queue_as :default

  PER_RUN = 200
  # TMDB gains trailers: a title it had none for is asked about again, after
  # everything that hasn't been asked at all.
  ASK_AGAIN = T.let(30.days, ActiveSupport::Duration)

  sig { void }
  def perform
    return unless AppSetting.current.fetch_trailers

    Household.find_each do |household|
      next if Tmdb::Client.for(household).nil?

      jobs = [ Movie, Show ].flat_map { |model| due(model, household).map { |id| CheckTrailerJob.new(model.name, id) } }
      ActiveJob.perform_all_later(jobs)
    end
    Trailer.unscoped.where(state: Trailer::State::Failed.serialize, attempts: ...Trailer::MAX_ATTEMPTS)
      .where(updated_at: ...20.hours.ago).find_each { |trailer| FetchTrailerJob.perform_later(trailer.id) }
  end

  private

  sig { params(model: T.untyped, household: Household).returns(T::Array[String]) }
  def due(model, household)
    model.unscoped.where(household_id: household.id).where.not(tmdb_id: nil)
      .where.not(id: Trailer.unscoped.where(owner_type: model.name).select(:owner_id))
      .where("trailer_checked_at IS NULL OR trailer_checked_at < ?", ASK_AGAIN.ago)
      .order(Arel.sql("trailer_checked_at ASC NULLS FIRST")).limit(PER_RUN).pluck(:id)
  end
end

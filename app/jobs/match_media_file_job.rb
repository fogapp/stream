# typed: strict
# frozen_string_literal: true

# Files one probed file under its movie or episode (PROPOSAL §5.2).
#
# One match per library at a time: two episodes of a new show matched in
# parallel would both create the show, and two copies of a film would both
# create the movie. The provider cache makes serial cheap after the first
# file of each title.
class MatchMediaFileJob < ApplicationJob
  extend T::Sig

  queue_as :analyze
  # The library comes with the job, so a rematch of thousands isn't a query
  # apiece to enqueue.
  limits_concurrency to: 1, key: ->(_media_file_id, library_id) { "match_library:#{library_id}" }
  # Bad data in, same bad data out: the AnalysisRun already holds the reason.
  discard_on Catalog::FileMatcher::Unplaceable
  # TMDB rate limits and outages heal; wait them out.
  retry_on UpstreamHttpClient::RateLimitError, wait: 1.minute, attempts: 10
  retry_on Tmdb::Client::Error, wait: :polynomially_longer, attempts: 5

  # One job per file, each carrying its library: one query for them all.
  sig { params(media_file_ids: T::Array[String]).returns(T::Array[MatchMediaFileJob]) }
  def self.for_files(media_file_ids)
    MediaFile.unscoped.where(id: media_file_ids).pluck(:id, :library_id).map { |id, library_id| new(id, library_id) }
  end

  sig { params(media_file_id: String, _library_id: String).void }
  def perform(media_file_id, _library_id)
    media_file = MediaFile.unscoped.find_by(id: media_file_id)
    return if media_file.nil? || media_file.state_enum != MediaFile::State::Probed

    Catalog::FileMatcher.new(media_file).call
  end

  sig { override.params(error: Exception).returns(T::Boolean) }
  def report_death?(error) = !error.is_a?(Catalog::FileMatcher::Unplaceable)
end

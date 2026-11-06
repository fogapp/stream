# typed: strict
# frozen_string_literal: true

# Refiles every file whose title isn't matched yet — unmatched or waiting in
# Needs match — when a TMDB key is first added, or from "Match again"
# (PROPOSAL §5.2). Fans out only.
class RematchLibrariesJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: ->(household_id, _library_id = nil) { "rematch:#{household_id}" }

  sig { params(household_id: String, library_id: T.nilable(String)).void }
  def perform(household_id, library_id = nil)
    libraries = Library.unscoped.where(household_id: household_id)
    libraries = libraries.where(id: library_id) if library_id
    library_ids = libraries.pluck(:id)

    unmatched_movies = Movie.unscoped.where(library_id: library_ids).needing_match.select(:id)
    unmatched_shows = Show.unscoped.where(library_id: library_ids).needing_match.select(:id)
    episode_ids = Episode.where(show_id: unmatched_shows).select(:id)

    file_ids = Edition.where(playable_type: "Movie", playable_id: unmatched_movies)
      .or(Edition.where(playable_type: "Episode", playable_id: episode_ids))
      .distinct.pluck(:media_file_id)
    ActiveJob.perform_all_later(MatchMediaFileJob.for_files(file_ids))
  end
end

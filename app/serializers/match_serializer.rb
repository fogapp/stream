# typed: strict
# frozen_string_literal: true

module MatchSerializer
  extend T::Sig

  sig { params(title: T.any(Movie, Show)).returns(T::Hash[Symbol, T.untyped]) }
  def self.title_json(title)
    {
      kind: title.is_a?(Movie) ? "movie" : "show", id: title.id, title: title.title, year: title.year,
      library: { id: title.library_id, name: title.library&.name },
      folder: title.is_a?(Show) ? title.folder : nil,
      match_state: title.match_state_enum, match_score: title.match_score,
      match_summary: title.match_reasons["summary"], candidates: title.match_candidates,
      tmdb_id: title.tmdb_id, poster_path: title.poster_path
    }
  end

  # A show filed from more than one folder: one show to Stream, but copies
  # on the share someone may want to tidy up in Sonarr.
  sig { params(show: Show).returns(T::Hash[Symbol, T.untyped]) }
  def self.folders_json(show)
    roots = show.library&.roots || []
    {
      id: show.id, title: show.title, year: show.year, library: { id: show.library_id, name: show.library&.name },
      folders: show.folders.map { |row| { folder: row.folder, paths: roots.map { |root| File.join(root, row.folder) } } }
    }
  end
end

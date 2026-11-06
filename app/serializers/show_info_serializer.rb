# typed: strict
# frozen_string_literal: true

# Everything Stream holds about one show, raw, for an admin working out why
# it looks the way it does (a duplicate, a wrong match, a missing season):
# where its folder is, which ids and match reasons it carries, every file
# filed under it and the folders they're really in, and any other show
# that looks like the same series.
module ShowInfoSerializer
  extend T::Sig

  sig { params(show: Show).returns(T::Hash[Symbol, T.untyped]) }
  def self.json(show)
    library = show.library
    editions = Edition.where(playable_type: "Episode", playable_id: show.episodes.select(:id))
      .includes(:media_file, :playable).to_a
    files = editions.filter_map do |edition|
      file = edition.media_file
      episode = edition.playable
      next if file.nil? || !episode.is_a?(Episode)

      { id: file.id, path: file.path, size: file.size, state: file.state_enum, missing_since: file.missing_since,
        episode: { id: episode.id, code: episode.code, season_number: episode.season_number } }
    end.sort_by { |file| file[:path] }

    {
      id: show.id, title: show.title, original_title: show.original_title, sort_title: show.sort_title, year: show.year,
      status: show.status, created_at: show.created_at, updated_at: show.updated_at,
      metadata_refreshed_at: show.metadata_refreshed_at,
      library: { id: library&.id, name: library&.name, roots: library&.roots || [] },
      folder: show.folder,
      folder_paths: (library&.roots || []).map { |root| File.join(root, show.folder) },
      # Every folder it's filed from: two copies of one show share it.
      folders: show.folders.map do |row|
        { folder: row.folder, paths: (library&.roots || []).map { |root| File.join(root, row.folder) } }
      end,
      ids: { tmdb_id: show.tmdb_id, tvdb_id: show.tvdb_id, imdb_id: show.imdb_id },
      match: { state: show.match_state_enum, score: show.match_score, summary: show.match_reasons&.dig("summary") },
      counts: { seasons: show.seasons.count, episodes: show.episodes.count, files: files.size,
                missing_files: files.count { |file| file[:state] == MediaFile::State::Missing } },
      # Where the files really are: a show filed from one folder but with
      # files somewhere else is how a stray copy shows itself.
      directories: files.group_by { |file| File.dirname(file[:path]) }.map { |dir, within| { path: dir, files: within.size } },
      files: files,
      look_alikes: look_alikes(show).map do |other|
        { id: other.id, title: other.title, year: other.year, folder: other.folder, library: other.library&.name,
          tmdb_id: other.tmdb_id, match_state: other.match_state_enum }
      end
    }
  end

  # Other shows that are probably this one: the same TMDB or TVDB id, or
  # the same name — each filed from its own folder.
  sig { params(show: Show).returns(T::Array[Show]) }
  def self.look_alikes(show)
    scope = Show.where.not(id: show.id).includes(:library)
    same = scope.where("lower(title) = lower(?)", show.title)
    same = same.or(scope.where(tmdb_id: show.tmdb_id)) if show.tmdb_id
    same = same.or(scope.where(tvdb_id: show.tvdb_id)) if show.tvdb_id
    same.order(:folder).to_a
  end
end

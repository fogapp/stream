# typed: strict
# frozen_string_literal: true

module Catalog
  # "Not this show" on one of a show's folders (PROPOSAL §5.2): the undo for
  # a merge, or for a wrong match. A show filed from several folders gives
  # this one up to a show of its own; a show with only this folder keeps it.
  # Either way the folder's show goes to Needs match with the title it isn't
  # remembered, so no scan or rematch picks that title for it again.
  module ShowSplit
    extend T::Sig

    sig { params(show: Show, folder: String, by: String, client: T.nilable(Tmdb::Client)).returns(Show) }
    def self.call(show, folder, by:, client:)
      row = show.folders.find_by!(folder: folder)
      title, year = Media::NameParser.show_title(folder)
      rejected = (Array(show.match_reasons["rejected"]) | [ show.tmdb_id ].compact)
      candidates = client ? TitleMatcher.new(client).search(Library::Kind::Shows, title, year: year) : []
      candidates = candidates.reject { |candidate| rejected.include?(candidate.tmdb_id) }

      split = Show.transaction do
        owner = show.folders.many? ? separate(show, row, title, year) : show
        owner.update!(tmdb_id: nil, match_state: Matchable::State::NeedsReview.serialize, match_score: nil,
          match_candidates: candidates.map(&:to_h),
          match_reasons: { "rejected" => rejected, "summary" => "#{by} said this isn't #{show.title}." })
        owner
      end
      refile(split, folder)
      split
    end

    sig { params(show: Show, row: ShowFolder, title: String, year: T.nilable(Integer)).returns(Show) }
    def self.separate(show, row, title, year)
      # `shows.folder` is unique too: the show keeps one of its other folders.
      show.update!(folder: T.must(show.folders.where.not(id: row.id).first).folder) if show.folder == row.folder
      split = Show.create!(household_id: show.household_id, library_id: show.library_id, folder: row.folder,
        title: title, year: year)
      row.update!(show: split)
      Activity.record(source: "library", event: "show.split", subject: split, household_id: show.household_id,
        summary: "#{row.folder} no longer files under #{show.title}")
      split
    end
    private_class_method :separate

    # The folder's files find their episodes again, now under its own show;
    # the episodes they leave behind keep their watch state.
    sig { params(show: Show, folder: String).void }
    def self.refile(show, folder)
      files = MediaFile.unscoped.where(library_id: show.library_id)
      within = (show.library&.roots || []).map do |root|
        files.where("path LIKE ?", "#{MediaFile.sanitize_sql_like(File.join(root, folder))}/%")
      end.reduce(:or)
      return if within.nil?

      jobs = within.pluck(:id, :library_id).map { |id, library_id| MatchMediaFileJob.new(id, library_id) }
      ActiveJob.perform_all_later(jobs) if jobs.any?
    end
    private_class_method :refile
  end
end

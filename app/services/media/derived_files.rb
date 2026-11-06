# typed: strict
# frozen_string_literal: true

module Media
  # What Stream made from a file, kept outside the library (CLAUDE.md,
  # media invariant 1): trickplay sheets and extracted subtitles in
  # `storage`, optimized versions in `cache`. A file's go when its row
  # does; `sweep` finds any whose row went without them — a library
  # deleted takes its files' rows in one statement, with no callbacks.
  # Only ever these folders, and only names that are a row's id.
  module DerivedFiles
    extend T::Sig

    ID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    BATCH = 1_000

    # A media file's own folders.
    sig { params(media_file_id: String).void }
    def self.remove(media_file_id)
      return unless ID.match?(media_file_id)

      FileUtils.rm_rf([ Trickplay.root.join(media_file_id), Subtitles::Extractor.root.join(media_file_id) ])
    end

    # Folders and versions whose row is gone; how many went.
    sig { returns(Integer) }
    def self.sweep
      folders = [ Trickplay.root, Subtitles::Extractor.root ].flat_map { |root| children(root).select(&:directory?) }
      gone = orphans(folders, MediaFile.unscoped) { |path| path.basename.to_s }
      versions = children(OptimizedVersion.root).select { |path| path.extname == ".mp4" }
      # "<id>.mp4", or "<id>.partial.mp4" mid-encode.
      gone += orphans(versions, OptimizedVersion.unscoped) { |path| path.basename.to_s.split(".").first.to_s }
      gone.each { |path| FileUtils.rm_rf(path) }
      gone.size
    end

    sig { params(root: Pathname).returns(T::Array[Pathname]) }
    def self.children(root) = root.directory? ? root.children : []
    private_class_method :children

    # The paths whose id (by the block) no row of `model` has.
    sig do
      params(paths: T::Array[Pathname], model: T.untyped, id_of: T.proc.params(path: Pathname).returns(String)).returns(T::Array[Pathname])
    end
    def self.orphans(paths, model, &id_of)
      named = paths.filter_map { |path| [ id_of.call(path), path ] if ID.match?(id_of.call(path)) }
      named.each_slice(BATCH).flat_map do |slice|
        kept = model.where(id: slice.map(&:first)).pluck(:id).to_set
        slice.reject { |id, _| kept.include?(id) }.map(&:last)
      end
    end
    private_class_method :orphans
  end
end

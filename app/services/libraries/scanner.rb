# typed: strict
# frozen_string_literal: true

module Libraries
  # Walks a library's roots and brings media_files in line with the disk
  # (PROPOSAL §5.1): new and changed files are queued for probing, vanished
  # ones marked missing, and missing ones past their grace deleted.
  #
  # The lesson this is built around: a NAS share that has dropped off looks
  # exactly like an empty folder. A scan that trusted it would mark the whole
  # library missing and, a month later, delete everyone's watch history. So a
  # root that can't be read, or that reads as empty while Stream knows files
  # under it, fails the scan instead — and a failed scan changes nothing
  # (hook's "checkpoints advance only on full success"). A folder inside a
  # root that can't be read is the same lesson, smaller (Libraries::Walker):
  # what's under it stays as it is, and the scan says so.
  class Scanner
    extend T::Sig

    class RootUnavailable < StandardError; end

    # A known file as the walk reads it: id, path, size, mtime, state and
    # its remembered sidecar subtitles.
    Row = T.type_alias { [ String, String, Integer, ActiveSupport::TimeWithZone, String, T.untyped ] }

    class Counts < T::Struct
      extend T::Sig

      prop :seen, Integer, default: 0
      prop :added, Integer, default: 0
      prop :changed, Integer, default: 0
      prop :missing, Integer, default: 0
      prop :purged, Integer, default: 0
      # What couldn't be read, and so wasn't judged.
      prop :unread, T::Array[String], factory: -> { [] }

      sig { returns(T::Hash[String, Integer]) }
      def to_h = { "seen" => seen, "added" => added, "changed" => changed, "missing" => missing, "purged" => purged, "unread" => unread.size }
    end

    # Synology and macOS litter shares with these; none of them hold video
    # anyone means to watch.
    SKIPPED_DIRECTORIES = T.let(%w[@eaDir #recycle #snapshot .AppleDouble lost+found].to_set.freeze, T::Set[String])
    SAMPLE = /(\A|[\s._-])sample([\s._-]|\z)/i

    sig { params(library: Library, subpath: T.nilable(String)).void }
    def initialize(library, subpath: nil)
      @library = library
      @subpath = subpath
      @counts = T.let(Counts.new, Counts)
      @to_probe = T.let([], T::Array[String])
      @created = T.let(Set.new, T::Set[String])
      # Subtitle files seen in each folder, for the videos beside them.
      @subtitles = T.let(Hash.new { |hash, key| hash[key] = [] }, T::Hash[String, T::Array[String]])
    end

    sig { returns(Counts) }
    def call
      scope_roots.each { |root| reconcile(root) }
      purge_expired
      ActiveJob.perform_all_later(@to_probe.map { |id| ProbeMediaFileJob.new(id) }) if @to_probe.any?
      @counts
    end

    private

    # A targeted scan walks just the given path, which must sit inside one of
    # the library's roots; a full scan walks every root.
    sig { returns(T::Array[String]) }
    def scope_roots
      subpath = @subpath
      return @library.roots if subpath.nil?

      raise RootUnavailable, "#{subpath} is not inside this library's folders" unless @library.root_for(subpath)

      [ subpath ]
    end

    sig { params(root: String).void }
    def reconcile(root)
      on_disk = walk(root)
      known = MediaFile.unscoped.where(library_id: @library.id).where("path = :root OR path LIKE :prefix",
        root: root, prefix: "#{ActiveRecord::Base.sanitize_sql_like(root.chomp('/'))}/%")
      present_known = known.where.not(state: MediaFile::State::Missing.serialize)

      if on_disk.empty? && present_known.exists? && File.directory?(root)
        raise RootUnavailable, "#{root} reads as empty but Stream knows #{present_known.count} files there. " \
                               "Is the share mounted?"
      end

      rows = known.pluck(:id, :path, :size, :mtime, :state, :sidecar_subtitles).index_by { |row| row[1] }
      on_disk.each do |path, (size, mtime)|
        @counts.seen += 1
        upsert(path, size, mtime, rows[path])
      end
      mark_missing(rows.values.reject { |row| on_disk.key?(row[1]) || unread?(row[1]) })
      remember_subtitles(on_disk.keys, rows)
    end

    # Each video's sidecar subtitles, as this walk found them, so pressing
    # Play needn't list its folder (Subtitles::Tracks.sidecars). Written
    # only where they changed, compared with what the walk already read —
    # not read again in batches, ~30 queries a scan (Lucid, 2026-10-10). A
    # file new to this walk has nothing to compare with.
    sig { params(paths: T::Array[String], rows: T::Hash[String, Row]).void }
    def remember_subtitles(paths, rows)
      paths.each do |path|
        next if @created.include?(path)

        names = sidecars(path)
        known = rows[path]
        next if known && known[5] == names

        MediaFile.unscoped.where(household_id: @library.household_id, path: path)
          .update_all(sidecar_subtitles: names) # rubocop:disable Rails/SkipsModelValidations
      end
    end

    sig { params(path: String).returns(T::Array[String]) }
    def sidecars(path) = Subtitles::Tracks.sidecar_names(path, @subtitles.fetch(File.dirname(path), []))

    sig { params(path: String).returns(T::Boolean) }
    def unread?(path)
      @counts.unread.any? { |unread| path == unread || path.start_with?("#{unread}/") }
    end

    sig { params(root: String).returns(T::Hash[String, [ Integer, Time ]]) }
    def walk(root)
      raise RootUnavailable, "#{root} isn't readable. Is the share mounted?" unless File.readable?(root)

      found = {}
      if File.file?(root)
        found[root] = stat_of(root) if wanted_file?(root)
        return found.compact
      end

      walker = Walker.new(root, skip: ->(name) { name.start_with?(".") || SKIPPED_DIRECTORIES.include?(name) })
      walker.each_file do |path, info|
        name = File.basename(path)
        if Subtitles::Tracks::SIDECAR_EXTENSIONS.key?(File.extname(name).downcase)
          T.must(@subtitles[File.dirname(path)]) << name
        elsif wanted_file?(path)
          found[path] = timestamped(info)
        end
      end
      # A mount dropping mid-walk reads as files going one by one, down to
      # an empty root.
      raise RootUnavailable, "#{root} went from under the scan. Is the share mounted?" if walker.vanished? && Dir.children(root).empty?

      @counts.unread.concat(walker.unread)
      found
    rescue SystemCallError => e
      raise RootUnavailable, "Couldn't read #{root}: #{e.message}"
    end

    sig { params(path: String).returns(T::Boolean) }
    def wanted_file?(path)
      name = File.basename(path)
      return false if name.start_with?(".") # includes macOS ._ resource forks
      return false unless MediaFile.video_path?(path)

      !File.basename(path, ".*").match?(SAMPLE) && !File.basename(File.dirname(path)).casecmp?("sample")
    end

    sig { params(path: String).returns(T.nilable([ Integer, Time ])) }
    def stat_of(path)
      timestamped(File.stat(path))
    rescue Errno::ENOENT
      nil
    end

    sig { params(info: File::Stat).returns([ Integer, Time ]) }
    def timestamped(info) = [ info.size, info.mtime.utc.floor ]

    sig do
      params(path: String, size: Integer, mtime: Time,
        row: T.nilable(Row)).void
    end
    def upsert(path, size, mtime, row)
      if row.nil?
        file = MediaFile.create!(household_id: @library.household_id, library_id: @library.id, path: path,
          size: size, mtime: mtime, state: MediaFile::State::Discovered.serialize, sidecar_subtitles: sidecars(path))
        @created << path
        @counts.added += 1
        @to_probe << file.id
        return
      end

      id, _path, known_size, known_mtime, state = row
      changed = known_size != size || known_mtime.to_i != mtime.to_i
      reappeared = state == MediaFile::State::Missing.serialize
      stuck = state == MediaFile::State::Discovered.serialize
      return unless changed || reappeared || stuck

      MediaFile.unscoped.where(id: id).update_all(size: size, mtime: mtime, missing_since: nil, # rubocop:disable Rails/SkipsModelValidations
        state: MediaFile::State::Discovered.serialize, updated_at: Time.current)
      @counts.changed += 1 if changed || reappeared
      @to_probe << id
    end

    sig { params(rows: T::Array[Row]).void }
    def mark_missing(rows)
      ids = rows.reject { |row| row[4] == MediaFile::State::Missing.serialize }.map(&:first)
      return if ids.empty?

      MediaFile.unscoped.where(id: ids).update_all(state: MediaFile::State::Missing.serialize, # rubocop:disable Rails/SkipsModelValidations
        missing_since: Time.current, updated_at: Time.current)
      @counts.missing += ids.size
    end

    # Only on a full scan that saw everything: a targeted scan, or one that
    # couldn't read a folder, saw too little to judge.
    sig { void }
    def purge_expired
      return unless @subpath.nil? && @counts.unread.empty?

      expired = MediaFile.unscoped.where(library_id: @library.id, state: MediaFile::State::Missing.serialize)
        .where(missing_since: ...MediaFile::MISSING_GRACE.ago)
      @counts.purged = expired.count
      expired.destroy_all if @counts.purged.positive?
    end
  end
end

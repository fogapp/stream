# typed: strict
# frozen_string_literal: true

module Libraries
  # Notices what has arrived in a library between hourly scans (PROPOSAL
  # §5.1). The NAS sends no change events, but a folder's mtime moves when
  # something is added to it, so listing the top of each root — and, in a
  # shows library, each show's folders — finds where to look in a second or
  # two where a full walk takes minutes. Each folder that changed gets a
  # targeted scan of just that folder.
  #
  # What this can't see is left to the hourly scan: a file replaced deep
  # inside a folder, a copy that puts a folder's old mtime back, and
  # anything removed (missing is never urgent).
  class ChangeDetector
    extend T::Sig

    # A folder still being copied into is left until it has been quiet this
    # long, so a scan doesn't probe half a file. ctime, not mtime: Finder and
    # rsync put back a copied file's mtime, but nothing can put back a ctime.
    SETTLE = T.let(2.minutes, ActiveSupport::Duration)
    # More changed folders than this is a reorganization: scan it all.
    MAX_TARGETED = 25
    # Folder listings and stats in flight at once over the share.
    LOOKUPS_AT_ONCE = 8

    sig { params(library: Library, now: T.any(Time, ActiveSupport::TimeWithZone)).void }
    def initialize(library, now: Time.current)
      @library = library
      @now = T.let(now.to_time, Time)
    end

    # The paths queued for a scan — or the library's roots, for a full one.
    sig { returns(T::Array[String]) }
    def call
      changed = @library.roots.flat_map { |root| reconcile(root) }
      changed = outermost(changed)
      return [] if changed.empty?

      if changed.size > MAX_TARGETED
        ScanLibraryJob.perform_later(@library.id)
        return @library.roots
      end
      ActiveJob.perform_all_later(changed.map { |path| ScanLibraryJob.new(@library.id, path) })
      changed
    end

    private

    sig { returns(Integer) }
    def depth = @library.kind_enum == Library::Kind::Shows ? 2 : 1

    # Records what the root holds now and returns what changed in it. The
    # first look at a root only records: everything there is "new" to it,
    # and the hourly scan already knows it.
    sig { params(root: String).returns(T::Array[String]) }
    def reconcile(root)
      current = list(root)
      return [] if current.nil?

      row = FolderListing.unscoped.find_or_initialize_by(library_id: @library.id, root: root) do |listing|
        listing.household_id = @library.household_id
      end
      previous = T.let(row.entries, T::Hash[String, Integer])
      # A share that has dropped off reads as empty (Scanner's lesson):
      # recording that would make everything "new" when it comes back.
      return [] if current.empty? && previous.any?

      if row.new_record?
        row.update!(entries: current)
        return []
      end

      kept = T.let({}, T::Hash[String, Integer])
      changed = T.let([], T::Array[String])
      current.each do |relative, mtime|
        if previous[relative] == mtime
          kept[relative] = mtime
        elsif settling?(File.join(root, relative))
          # Looked at again next time, as changed again.
          kept[relative] = T.must(previous[relative]) if previous.key?(relative)
        else
          kept[relative] = mtime
          changed << File.join(root, relative)
        end
      end
      row.update!(entries: kept) if kept != previous
      changed
    end

    # Each folder (and loose video) down to this library's depth, with its
    # mtime; nil when the root can't be read.
    sig { params(root: String).returns(T.nilable(T::Hash[String, Integer])) }
    def list(root)
      return nil unless File.directory?(root) && File.readable?(root)

      found = T.let({}, T::Hash[String, Integer])
      level = T.let([ "" ], T::Array[String])
      depth.times do
        candidates = in_parallel(level) do |relative|
          children(File.join(root, relative)).map { |name| relative.empty? ? name : File.join(relative, name) }
        end.flatten
        stats = in_parallel(candidates) { |child| stat(File.join(root, child)) }
        level = candidates.zip(stats).filter_map do |child, stat|
          next if stat.nil? || !(stat.directory? || MediaFile.video_path?(child))

          found[child] = stat.mtime.to_i
          child if stat.directory?
        end
      end
      found
    end

    # `items` mapped a few at a time, in order. A stat over the NAS is a
    # round trip that leaves the CPU idle, and a shows library is thousands
    # of them every five minutes: one after another they were half of all
    # job time (Glass, 2026-10-22: p95 26 s, 85% of it in File.stat).
    sig do
      type_parameters(:In, :Out)
        .params(items: T::Array[T.type_parameter(:In)], blk: T.proc.params(item: T.type_parameter(:In)).returns(T.type_parameter(:Out)))
        .returns(T::Array[T.type_parameter(:Out)])
    end
    def in_parallel(items, &blk)
      return items.map(&blk) if items.size < 2

      slices = items.each_slice((items.size / LOOKUPS_AT_ONCE.to_f).ceil).to_a
      slices.map { |slice| Thread.new { slice.map(&blk) } }.flat_map(&:value)
    end

    # A folder that went away while being listed has nothing in it.
    sig { params(folder: String).returns(T::Array[String]) }
    def children(folder)
      Dir.children(folder).reject { |name| name.start_with?(".") || Scanner::SKIPPED_DIRECTORIES.include?(name) }
    rescue SystemCallError
      []
    end

    sig { params(path: String).returns(T.nilable(File::Stat)) }
    def stat(path)
      File.stat(path)
    rescue SystemCallError
      nil
    end

    # Something in it was written to within SETTLE.
    sig { params(path: String).returns(T::Boolean) }
    def settling?(path)
      stat = stat(path)
      return false if stat.nil?

      paths = stat.directory? ? children(path).map { |name| File.join(path, name) } : []
      [ stat, *paths.filter_map { |child| stat(child) } ].any? { |each| each.ctime > @now - SETTLE }
    end

    # A new show and its new season are one scan, of the show.
    sig { params(paths: T::Array[String]).returns(T::Array[String]) }
    def outermost(paths)
      paths.reject { |path| paths.any? { |other| other != path && path.start_with?("#{other}/") } }
    end
  end
end

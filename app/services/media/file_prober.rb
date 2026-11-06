# typed: strict
# frozen_string_literal: true

module Media
  # Takes a discovered file to probed (or broken): fingerprint, move
  # detection, ffprobe, streams (PROPOSAL §5.1, §5.3). Every run leaves an
  # AnalysisRun for the probe step.
  class FileProber
    extend T::Sig

    class Outcome < T::Enum
      include ApplicationEnum
      enums do
        Probed = new("probed")
        # The same content was already known as a missing file; that row
        # took this path and this one was dropped.
        Moved = new("moved")
        Broken = new("broken")
        # Gone before we got to it; the next scan marks it missing.
        Vanished = new("vanished")
      end
    end

    sig { params(media_file: MediaFile).void }
    def initialize(media_file)
      @media_file = media_file
    end

    sig { returns(Outcome) }
    def call
      return Outcome::Vanished unless File.file?(@media_file.path)

      fingerprint = fingerprint_of(@media_file)
      moved_from = relocatable_twin(fingerprint)
      return adopt(moved_from) if moved_from

      probe_into(@media_file, fingerprint)
    end

    private

    # The share wouldn't read it (EIO, EACCES, gone midway): left to be
    # probed again, but never silently — its probe run and the file say why.
    sig { params(file: MediaFile).returns(String) }
    def fingerprint_of(file)
      Fingerprint.compute(file.path)
    rescue SystemCallError => e
      file.update!(last_error: "Couldn't read the file: #{e.message}".truncate(500))
      AnalysisRun.track(file, AnalysisRun::Step::Probe) { raise e }
    end

    # A row with the same content in the same household whose own file has
    # gone: the file was renamed or moved. A scan needn't have noticed yet —
    # the change detector doesn't look for removals, so a renamed folder's
    # new path is usually reached first. A twin still on disk is a copy.
    sig { params(fingerprint: String).returns(T.nilable(MediaFile)) }
    def relocatable_twin(fingerprint)
      twins = MediaFile.unscoped.where(household_id: @media_file.household_id, fingerprint: fingerprint).where.not(id: @media_file.id).to_a
      missing, present = twins.partition { |twin| twin.state_enum == MediaFile::State::Missing }
      missing.max_by { |twin| twin.missing_since.to_f } || present.find { |twin| vacated?(twin) }
    end

    # Its path is gone from a library that can be read: a dropped share
    # says "not there" too, of everything on it.
    sig { params(twin: MediaFile).returns(T::Boolean) }
    def vacated?(twin)
      roots = Library.unscoped.find_by(id: twin.library_id)&.roots.to_a
      root = roots.find { |candidate| Media::SafePath.within?(twin.path, candidate) }
      return false if root.nil? || Dir.children(root).empty?

      gone?(twin.path)
    rescue SystemCallError
      false
    end

    sig { params(path: String).returns(T::Boolean) }
    def gone?(path)
      File.lstat(path)
      false
    rescue Errno::ENOENT, Errno::ENOTDIR
      true
    end

    # The old row keeps its id — and with it every watch state, match and
    # analysis artefact — and takes the new path. The new row goes. A twin
    # that never read has nothing worth keeping as Probed: it's read here,
    # at its new path, by a probe of its own.
    sig { params(twin: MediaFile).returns(Outcome) }
    def adopt(twin)
      new_path = @media_file.path
      old_path = twin.path
      read = twin.probed_at.present?
      MediaFile.transaction do
        @media_file.destroy!
        twin.update!(path: new_path, library_id: @media_file.library_id, size: @media_file.size, mtime: @media_file.mtime,
          state: (read ? MediaFile::State::Probed : MediaFile::State::Discovered).serialize, missing_since: nil)
      end
      ProbeMediaFileJob.perform_later(twin.id) unless read
      Activity.record(source: "library", event: "media_file.moved", subject: twin, household_id: twin.household_id,
        summary: "#{File.basename(new_path)} moved from #{File.dirname(old_path)} to #{File.dirname(new_path)}",
        payload: { from: old_path, to: new_path })
      Outcome::Moved
    end

    sig { params(file: MediaFile, fingerprint: String).returns(Outcome) }
    def probe_into(file, fingerprint)
      result = AnalysisRun.track(file, AnalysisRun::Step::Probe, tool_version: ToolRunner.version("ffprobe")) do
        Probe.run(file.path)
      end
      # Other content at the same path (Sonarr's upgrade replaced it): what
      # was worked out from the old content goes with its streams —
      # the old encode's keyframes
      # planned the new one's remux, and its optimized version played instead.
      replaced = file.fingerprint.present? && file.fingerprint != fingerprint
      MediaFile.transaction do
        file.media_streams.delete_all
        now = Time.current
        rows = result.streams.map { |stream| stream.merge(media_file_id: file.id, created_at: now, updated_at: now) }
        MediaStream.insert_all!(rows) if rows.any?
        file.update!(fingerprint: fingerprint, container: result.container, duration_seconds: result.duration_seconds,
          bit_rate: result.bit_rate, probe: result.raw.except("chapters"), chapters: result.chapters, probed_at: now,
          state: MediaFile::State::Probed.serialize, start_time: result.raw.dig("format", "start_time").to_s.presence&.to_f,
          last_error: result.warning, **(replaced ? { keyframes: nil, keyframes_source: nil } : {}))
      end
      forget_old_content(file) if replaced
      Outcome::Probed
    rescue ToolRunner::Timeout => e
      # A busy share, not a broken file:
      # left to be probed again (ProbeMediaFileJob retries), never Broken.
      file.update!(last_error: "Probing timed out: #{e.message}".truncate(500))
      raise
    rescue Probe::Error, ToolRunner::Error => e
      file.update!(fingerprint: fingerprint, state: MediaFile::State::Broken.serialize, last_error: e.message.truncate(500))
      Activity.record(source: "library", event: "media_file.broken", severity: Activity::Severity::Warn,
        subject: file, household_id: file.household_id,
        summary: "Couldn't read #{file.filename}: #{e.message.truncate(200)}")
      Outcome::Broken
    end

    # An optimized version made from the old content is made again from the
    # new, rather than played in its place.
    sig { params(file: MediaFile).void }
    def forget_old_content(file)
      # What plays taught about the old content isn't about the new (R3).
      Playability.unscoped.where(media_file_id: file.id).delete_all
      version = OptimizedVersion.unscoped.find_by(media_file_id: file.id)
      return if version.nil? || !%w[ready encoding].include?(version.state)

      FileUtils.rm_f([ version.path, version.partial_path ])
      version.requeue!
    end
  end
end

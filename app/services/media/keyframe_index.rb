# typed: strict
# frozen_string_literal: true

module Media
  # Builds a file's keyframe index (PROPOSAL §5.3): the container's own
  # index when it has one, the packet scan otherwise.
  module KeyframeIndex
    extend T::Sig

    # Where a scan someone's play asked for runs: nothing pauses it.
    PLAY_QUEUE = "index"

    class Source < T::Enum
      include ApplicationEnum
      enums do
        Cues = new("cues")
        Stss = new("stss")
        Packets = new("packets")
        # Tried, and there's no index to be had: the packet scan couldn't
        # read it through. A copy can't be planned, so it's converted
        # instead, and nothing asks for the scan again until the file changes.
        None = new("none")
      end
    end

    # The cheap way, or nil when this file needs the packet scan.
    sig { params(file: MediaFile).returns(T.nilable([ T::Array[Integer], Source ])) }
    def self.from_container(file)
      container = file.container.to_s
      if container.include?("matroska")
        times = Keyframes::Matroska.new(file.path).keyframes_ms
        return [ times, Source::Cues ] if times
      elsif container.include?("mp4") || container.include?("mov")
        times = Keyframes::Mp4.new(file.path).keyframes_ms
        return [ times, Source::Stss ] if times
      end
      nil
    end

    # The container's index, read now and stored, with its AnalysisRun;
    # nil when there isn't one and the file needs the packet scan, whose
    # step this leaves pending: nothing's been indexed yet.
    sig { params(file: MediaFile).returns(T.nilable([ T::Array[Integer], Source ])) }
    def self.index_from_container!(file)
      run = AnalysisRun.begin!(file, AnalysisRun::Step::Keyframes)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      found = from_container(file)
      if found
        store(file, *found)
        run.succeed!(duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round, tool_version: "container-index")
      else
        AnalysisRun.forget!(file, AnalysisRun::Step::Keyframes)
      end
      found
    rescue StandardError => e
      run&.fail!(e)
      raise
    end

    # The packet scan itself, with its AnalysisRun. hold: the heavy queue's,
    # so the read stands still while someone watches; a play's own scan (the
    # index queue) passes none. A file that can't be read through is marked
    # as having no index, and isn't scanned again on every press of Play:
    # its AnalysisRun says so in Needs attention.
    sig { params(file: MediaFile, hold: T.nilable(ToolRunner::Hold)).returns(T::Boolean) }
    def self.scan!(file, hold:)
      AnalysisRun.track(file, AnalysisRun::Step::Keyframes, tool_version: ToolRunner.version("ffprobe")) do
        store(file, Keyframes::PacketScan.keyframes_ms(file.path, duration_seconds: file.duration_seconds, stream: file.primary_video&.index, hold: hold),
          Source::Packets)
      end
      true
    rescue Keyframes::PacketScan::Incomplete
      store(file, [], Source::None)
      true
    end

    # The packet scan reads the whole file (minutes for a remux on the NAS).
    # Asked for by a play, it runs on the index queue, which nothing pauses
    # while someone watches (HoldHeavyWhileWatchingJob pauses heavy): the
    # play converts meanwhile and the next one repackages.
    # Otherwise, on the heavy queue.
    # Queued once however often Play is pressed, and a play isn't taken for
    # the background scan already waiting: that one may wait for hours.
    sig { params(file: MediaFile, urgent: T::Boolean).void }
    def self.scan_later(file, urgent: false)
      return unless Rails.cache.write("stream/keyframe-scan/#{urgent ? 'play' : 'background'}/#{file.id}", true, unless_exist: true, expires_in: 30.minutes)

      priority = urgent ? AnalysisPriority::URGENT : AnalysisPriority.for(file)
      IndexKeyframesJob.set(queue: urgent ? PLAY_QUEUE : :heavy, priority: priority).perform_later(file.id, true)
    end

    # An index a copy can be planned from: one stored, and not the mark of
    # a scan that couldn't be done.
    sig { params(file: MediaFile).returns(T::Boolean) }
    def self.usable?(file) = !file.keyframes.nil? && file.keyframes_source != Source::None.serialize

    # Tried, and none to be had (Source::None).
    sig { params(file: MediaFile).returns(T::Boolean) }
    def self.unavailable?(file) = file.keyframes_source == Source::None.serialize

    # Whether a streamed copy can be planned now. The container's own index
    # is a few KB and read here; the packet scan reads the whole file, so
    # it's queued instead and the player asks again, rather than a thread
    # waiting minutes on the NAS.
    sig { params(file: MediaFile).returns(T::Boolean) }
    def self.ready_for_play!(file)
      return true if usable?(file)
      # Tried, and there's none to be had: converted, without asking again.
      return false if unavailable?(file)
      return true if index_from_container!(file)

      scan_later(file, urgent: true)
      false
    rescue StandardError => e
      # Recorded on the file's AnalysisRun (Needs attention); the scan may still manage.
      Rails.logger.warn("[playback] container keyframe index failed for #{file.id}: #{e.message}")
      scan_later(file, urgent: true)
      false
    end

    sig { params(file: MediaFile, times: T::Array[Integer], source: Source).void }
    def self.store(file, times, source)
      file.update!(keyframes: times, keyframes_source: source.serialize)
    end
  end
end

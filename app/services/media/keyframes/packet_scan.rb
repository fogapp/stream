# typed: strict
# frozen_string_literal: true

module Media
  module Keyframes
    # The fallback (PROPOSAL §5.3): ask ffprobe for every video packet's
    # flags. No decoding, but it reads the whole file — minutes for a 30 GB
    # remux over the NAS (spikes.md › B), past an hour when the share is
    # busy — so it runs on the heavy queue.
    module PacketScan
      extend T::Sig

      class Incomplete < ToolRunner::Error; end

      # No limit on how long the read takes, only on ffprobe going quiet: a
      # busy share reads at single-digit MB/s, and any budget per gigabyte
      # once timed out every scan on it, three times each.
      IDLE_TIMEOUT = 300

      # A damaged file can end the scan early with ffprobe still exiting 0
      # (matroska "invalid as first byte of an EBML number" gave two
      # keyframes for a 21-minute episode). An index that stops this far
      # short of the runtime is a failure, not an index.
      SHORT_BY_SECONDS = 60
      SHORT_BY_SHARE = 0.1

      # stream: the file's own picture, by index — "v:0" can be the cover
      # art an MP4 or MKV carries ahead of it. AVI's packets carry no
      # presentation time at all: +genpts makes them one, and failing that
      # the decode time stands in. They
      # were all dropped, and an AVI with H.264 in it never played.
      sig do
        params(path: String, duration_seconds: T.nilable(Float), stream: T.nilable(Integer), hold: T.nilable(ToolRunner::Hold))
          .returns(T::Array[Integer])
      end
      def self.keyframes_ms(path, duration_seconds: nil, stream: nil, hold: nil)
        times = T.let([], T::Array[Integer])
        result = ToolRunner.each_line(polite + [ "ffprobe", "-v", "error", "-protocol_whitelist", "file", "-fflags", "+genpts",
          "-select_streams", stream.nil? ? "v:0" : stream.to_s, "-show_entries", "packet=pts_time,dts_time,flags", "-of", "csv=p=0",
          "-i", "file:#{path}" ], idle_timeout: IDLE_TIMEOUT, hold: hold) do |line|
          pts, dts, flags = line.strip.split(",", 3)
          time = [ pts, dts ].find { |value| value.present? && value != "N/A" }
          times << (time.to_f * 1000).round if flags.to_s.start_with?("K") && time
        end
        raise ToolRunner::Error, "ffprobe exited #{result.status}: #{result.stderr.strip.lines.first}" unless result.success?

        complete!(times, duration_seconds: duration_seconds)
      end

      # The index a scan's keyframes make — the one read over the file
      # (OnePass) collects them the same way — or Incomplete.
      sig { params(times: T::Array[Integer], duration_seconds: T.nilable(Float)).returns(T::Array[Integer]) }
      def self.complete!(times, duration_seconds:)
        times = times.uniq.sort
        check_coverage!(times, duration_seconds)
        times
      end

      # A whole-file read while someone may be watching from the same share:
      # at the disk's idle priority where there is one (Linux), so playback's
      # reads come first.
      sig { returns(T::Array[String]) }
      def self.polite = File.executable?("/usr/bin/ionice") ? %w[/usr/bin/ionice -c3] : []

      sig { params(times: T::Array[Integer], duration_seconds: T.nilable(Float)).void }
      def self.check_coverage!(times, duration_seconds)
        return if duration_seconds.nil? || duration_seconds <= 0

        short_by = [ SHORT_BY_SECONDS, duration_seconds * SHORT_BY_SHARE ].max
        covered = (times.last || 0) / 1000.0
        return if covered >= duration_seconds - short_by

        raise Incomplete, "keyframes stop at #{covered.round}s of #{duration_seconds.round}s — the file may be damaged"
      end
      private_class_method :check_coverage!
    end
  end
end

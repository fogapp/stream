# typed: strict
# frozen_string_literal: true

module Markers
  # Chromaprint fingerprints of a file's opening and closing minutes, through
  # ffmpeg's chromaprint muxer (jellyfin-ffmpeg has it). Cached per file.
  module Fingerprinter
    extend T::Sig

    # There's nothing to fingerprint with, or to fingerprint: nothing a
    # retry could change, so DetectMarkersJob stands down quietly.
    class Unavailable < StandardError; end
    # ffmpeg couldn't read this file: its AnalysisRun says so.
    class ReadFailed < StandardError; end

    HEAD_SECONDS = 600
    TAIL_SECONDS = 420
    # How long a read may stand still. A whole episode off a slow share
    # outlasted the 15 min a read used to be given;
    # how long it takes is the share's business, like Media::OnePass.
    STALL_TIMEOUT = 300

    sig { returns(T::Boolean) }
    def self.available?
      @available = T.let(@available, T.nilable(T::Boolean))
      return @available unless @available.nil?

      @available = ToolRunner.run(%w[ffmpeg -hide_banner -h muxer=chromaprint], timeout: 20).stdout.include?("fp_format")
    rescue ToolRunner::Error
      @available = false
    end

    # hold: the heavy queue's (HoldHeavyWhileWatchingJob), so a read under
    # way stands still while someone watches instead of sharing the NAS
    # with their playback.
    sig { params(file: MediaFile, segment: AudioFingerprint::Segment, hold: T.nilable(ToolRunner::Hold)).returns(AudioFingerprint) }
    def self.for(file, segment, hold: nil)
      cached = AudioFingerprint.find_by(media_file: file, segment: segment.serialize)
      return cached if cached

      raise Unavailable, "this ffmpeg has no chromaprint muxer" unless available?

      duration = file.duration_seconds.to_f
      offset = segment == AudioFingerprint::Segment::Tail ? [ duration - TAIL_SECONDS, 0.0 ].max : 0.0
      length =
        case segment
        when AudioFingerprint::Segment::Tail then TAIL_SECONDS
        when AudioFingerprint::Segment::Head then HEAD_SECONDS
        when AudioFingerprint::Segment::Whole then duration.ceil + 1
        else T.absurd(segment)
        end
      audio = file.media_streams.find { |stream| stream.kind_enum == MediaStream::Kind::Audio }
      raise Unavailable, "no audio" if audio.nil?

      Tempfile.create([ "fingerprint", ".raw" ]) do |out|
        result = ToolRunner.run_advancing([ "ffmpeg", "-hide_banner", "-v", "error", "-nostdin", "-nostats", "-progress", "pipe:1", "-y",
          "-ss", format("%.3f", offset), "-t", length.to_s, "-protocol_whitelist", "file", "-i", "file:#{file.path}",
          "-map", "0:#{audio.index}", "-ac", "1", "-f", "chromaprint", "-fp_format", "raw", out.path ], stall_timeout: STALL_TIMEOUT, hold: hold)
        raise ReadFailed, "#{file.filename}: #{result.stderr.strip.lines.last}" unless result.success?

        # Unsigned 32-bit points, stored signed to fit an integer column.
        points = T.cast(File.binread(out.path).unpack("l<*"), T::Array[Integer])
        # Another season job may have read this file meanwhile: keep its print.
        AudioFingerprint.create_or_find_by!(media_file: file, segment: segment.serialize) do |print|
          print.offset_seconds = offset
          print.points = points
        end
      end
    end
  end
end

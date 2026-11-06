# typed: strict
# frozen_string_literal: true

module Media
  # EBU R128 loudness of a file's main audio (PROPOSAL §5.5), as its part of
  # the one read over the file (OnePass). Decodes the audio only; the
  # player turns the measurement into a gain, and nothing is re-encoded.
  module Loudness
    extend T::Sig

    class Measurement < T::Struct
      const :integrated, Float
      const :true_peak, Float
    end

    # ffmpeg's summary of the ebur128 filter, which it logs at the end.
    sig { params(stderr: String).returns(T.nilable(Measurement)) }
    def self.parse(stderr)
      summary = stderr.split("Summary:").last.to_s
      integrated = summary[/I:\s+(-?[\d.]+) LUFS/, 1]
      return nil if integrated.nil?

      peak = summary[/Peak:\s+(-?[\d.]+|-inf) dBFS/, 1]
      Measurement.new(integrated: integrated.to_f, true_peak: peak == "-inf" || peak.nil? ? -70.0 : peak.to_f)
    end

    class Part < OnePass::Part
      sig { params(file: MediaFile, audio: MediaStream).void }
      def initialize(file, audio)
        @file = file
        @audio = audio
      end

      sig { override.returns(AnalysisRun::Step) }
      def step = AnalysisRun::Step::Loudness

      sig { override.returns(T::Boolean) }
      def missing? = @file.loudness_lufs.nil?

      # The summary is logged at info.
      sig { override.returns(String) }
      def log_level = "info"

      sig { override.returns(T::Array[T::Array[String]]) }
      def outputs
        [ [ "-map", "0:#{@audio.index}", "-vn", "-af", "ebur128=peak=true:framelog=quiet", "-f", "null", "-" ] ]
      end

      sig { override.params(result: T.nilable(ToolRunner::Result), keyframes_ms: T::Array[Integer]).void }
      def finish(result, keyframes_ms)
        measurement = result && Loudness.parse(result.stderr)
        raise ToolRunner::Error, "no loudness in ffmpeg's summary" if measurement.nil?

        @file.update!(loudness_lufs: measurement.integrated, true_peak_dbfs: measurement.true_peak)
      end
    end
  end
end

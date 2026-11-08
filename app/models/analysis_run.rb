# typed: strict
# frozen_string_literal: true

# One row per file per analysis step (PROPOSAL §4.3): the file page renders
# them as a checklist, and Needs attention lists the failed ones. The row is
# the latest run of that step, updated in place.
#
# CLAUDE.md invariant 5: never stamp success on failure. A failure records
# the error and bumps consecutive_failures; finished_at and tool_version
# describe the last *successful* run and stay untouched, so staleness stays
# visible.
class AnalysisRun < ApplicationRecord
  extend T::Sig

  class Step < T::Enum
    include ApplicationEnum
    enums do
      Probe = new("probe")
      Keyframes = new("keyframes")
      Match = new("match")
      Artwork = new("artwork")
      Subtitles = new("subtitles")
      Trickplay = new("trickplay")
      Markers = new("markers")
      Loudness = new("loudness")
      Transcript = new("transcript")
      # Missing languages fetched from OpenSubtitles.
      SubtitleFetch = new("subtitle_fetch")
      # An optimized version encoded (OptimizedVersion).
      Optimize = new("optimize")
      # A hand-placed video's details asked of YouTube once it's identified
      # (Youtube::Hydrator).
      YoutubeDetails = new("youtube_details")
    end
  end

  class Status < T::Enum
    include ApplicationEnum
    enums do
      Pending = new("pending")
      Running = new("running")
      Succeeded = new("succeeded")
      Failed = new("failed")
    end
  end

  # A file's, or a live stream's (PROPOSAL §7.8): one, never both
  # (analysis_runs_one_owner).
  belongs_to :media_file, optional: true
  belongs_to :live_stream, optional: true

  attribute :step, Step
  attribute :status, Status

  scope :failed, -> { where(status: Status::Failed.serialize) }

  # "ffprobe version 9.0.2 Copyright (c) 2007-2026 the FFmpeg developers"
  # is "ffprobe 9.0.2" on the file page.
  sig { params(version: T.nilable(String)).returns(T.nilable(String)) }
  def self.short_version(version)
    match = version.to_s.match(/\A(\S+) version (\S+)/)
    match ? "#{match[1]} #{match[2]}" : version
  end

  sig { returns(T::Boolean) }
  def succeeded? = status_enum == Status::Succeeded

  # The row for `step`, marked running: a run that succeed! or fail! will
  # finish. track does both around a block; Media::OnePass finishes
  # several steps from one read.
  sig { params(subject: T.any(MediaFile, LiveStream), step: Step).returns(AnalysisRun) }
  def self.begin!(subject, step)
    # Two jobs can track one step at once (a transcript from subtitles and
    # one from Whisper): whichever inserts second finds the first's row.
    run = create_or_find_by!(**owner_of(subject), step: step.serialize)
    run.update!(status: Status::Running.serialize, started_at: Time.current)
    run
  end

  # Marks a step not done, so the next read over the file does it again
  # (Analysis::Rerun). What it made before stays until then.
  sig { params(subject: T.any(MediaFile, LiveStream), step: Step).void }
  def self.forget!(subject, step)
    find_by(**owner_of(subject), step: step.serialize)&.update!(status: Status::Pending.serialize)
  end

  sig { params(duration_ms: Integer, tool_version: T.nilable(String)).void }
  def succeed!(duration_ms:, tool_version: nil)
    update!(status: Status::Succeeded.serialize, finished_at: Time.current, duration_ms: duration_ms,
      tool_version: self.class.short_version(tool_version), error: nil, consecutive_failures: 0)
    Glass.increment("analysis.runs", tags: { step: step_enum.serialize, status: Status::Succeeded.serialize })
    Glass.timing("analysis.duration", duration_ms, tags: { step: step_enum.serialize })
  end

  sig { params(error: Exception).void }
  def fail!(error)
    update!(status: Status::Failed.serialize, error: "#{error.class}: #{error.message}".truncate(500),
      consecutive_failures: consecutive_failures + 1)
    Glass.increment("analysis.runs", tags: { step: step_enum.serialize, status: Status::Failed.serialize })
  end

  # Runs the block as `step` for a file (or a live stream), recording the
  # outcome. The block's exception is recorded and re-raised, so the job
  # still retries.
  sig do
    type_parameters(:R)
      .params(subject: T.any(MediaFile, LiveStream), step: Step, tool_version: T.nilable(String),
        block: T.proc.returns(T.type_parameter(:R)))
      .returns(T.type_parameter(:R))
  end
  def self.track(subject, step, tool_version: nil, &block)
    run = begin!(subject, step)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      result = yield
    rescue StandardError => e
      run.fail!(e)
      raise
    end
    run.succeed!(duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round, tool_version: tool_version)
    result
  end

  sig { params(subject: T.any(MediaFile, LiveStream)).returns(T::Hash[Symbol, T.untyped]) }
  def self.owner_of(subject)
    subject.is_a?(LiveStream) ? { live_stream: subject } : { media_file: subject }
  end
  private_class_method :owner_of
end

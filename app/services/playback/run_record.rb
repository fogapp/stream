# typed: strict
# frozen_string_literal: true

module Playback
  # A run's TranscodeRun row: how it ended and the end of what its ffmpeg
  # said, kept after the cache that held its log is swept.
  module RunRecord
    extend T::Sig

    # A run that never got going: its arguments, its spawn.
    sig { params(session: PlaybackSession, variant: Integer, gop: Integer, encoder: Encoders::Kind, error: StandardError).void }
    def self.unstartable(session, variant, gop, encoder, error)
      TranscodeRun.create(playback_session_id: session.id, state: TranscodeRun::State::Exited.serialize, variant: variant,
        start_gop: gop, encoder: encoder.serialize, failure: TranscodeRun::Failure::Unstartable.serialize,
        log_tail: "#{error.class}: #{error.message}", started_at: Time.current, finished_at: Time.current)
    end

    # The run's row says how it ended, once: a later stop doesn't overwrite
    # the failure already recorded.
    sig do
      params(run: Supervisor::Run, failure: T.nilable(TranscodeRun::Failure), log: T.proc.params(message: String).void,
        status: T.nilable(Integer), signal: T.nilable(Integer), tail: T.nilable(String)).void
    end
    def self.close(run, failure:, log:, status: nil, signal: nil, tail: nil)
      id = run.record_id
      return if id.nil?

      record = TranscodeRun.find_by(id: id)
      return if record.nil? || (record.finished_at && (record.failure || failure.nil?))

      record.finished!(failure: failure, status: status || record.exit_status, signal: signal, log_tail: tail.presence)
    rescue ActiveRecord::ActiveRecordError => e
      log.call("couldn't record run #{id}: #{e.message}")
    end

    # The end of what this run's ffmpeg said (its part of the session's log).
    sig { params(run: Supervisor::Run).returns(String) }
    def self.log_tail(run)
      log = Cache.directory(run.session_id, run.variant).join("ffmpeg.log")
      return "" unless log.file?

      size = log.size
      from = [ run.log_from, size - TranscodeRun::LOG_TAIL ].max
      File.open(log, "rb") do |file|
        file.seek(from)
        file.read.to_s.force_encoding(Encoding::UTF_8).scrub
      end
    rescue SystemCallError
      ""
    end
  end
end

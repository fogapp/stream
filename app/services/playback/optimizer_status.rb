# typed: strict
# frozen_string_literal: true

module Playback
  # What the optimizer is doing and, when it isn't, why not (the Playback
  # page's optimizer panel and its health check): the same rules
  # Optimizer#claim applies — quiet hours, the pause switch, the space
  # budget, a viewer converting live — plus whether anything is running to
  # encode at all.
  module OptimizerStatus
    extend T::Sig

    class State < T::Enum
      include ApplicationEnum
      enums do
        Encoding = new("encoding")
        # Something is waiting that nothing is running to encode.
        NoTranscoder = new("no_transcoder")
        Paused = new("paused")
        WaitingQuietHours = new("waiting_quiet_hours")
        OverBudget = new("over_budget")
        # A viewer's conversion has the machine.
        Busy = new("busy")
        # Free to start: the transcoder takes one on its next tick.
        Starting = new("starting")
        Idle = new("idle")
      end
    end

    # What an optimized version runs to, roughly: the video at six tenths of
    # its ceiling (it's encoded to a quality, under that) and stereo AAC.
    AUDIO_KBPS = 160

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def self.current
      setting = AppSetting.cached
      beat = TranscoderHeartbeat.current
      nodes = TranscodeNode.online.where(optimize: true).to_a
      queued = OptimizedVersion.queued
      used = OptimizedVersion.bytes_used
      full = used >= setting.optimize_budget_bytes
      eligible = OptimizedVersion.claimable(queued, setting, full: full)
      encoding = OptimizedVersion.where(state: OptimizedVersion::State::Encoding.serialize)
        .includes(media_file: { editions: { playable: :show } }).order(:started_at).to_a
      online = !beat.nil? || nodes.any?
      busy = beat&.busy == true && nodes.none? { |node| node.live_video_sessions.zero? }
      waiting = queued.count
      window = setting.quiet_window

      state =
        if encoding.any? then State::Encoding
        elsif waiting.zero? then State::Idle
        elsif !online then State::NoTranscoder
        elsif eligible.exists? then busy ? State::Busy : State::Starting
        elsif setting.optimize_paused then State::Paused
        elsif !setting.quiet_hours? then State::WaitingQuietHours
        elsif full then State::OverBudget
        else State::Starting
        end

      {
        state: state, message: message(state, waiting),
        paused: setting.optimize_paused, automatic: setting.optimize_automatically,
        quiet_hours: {
          start_hour: setting.optimize_quiet_start_hour, end_hour: setting.optimize_quiet_end_hour, now: setting.quiet_hours?,
          next_start_at: window&.first, ends_at: window&.last
        },
        transcoder: { online: !beat.nil?, last_seen_at: beat&.at, encoder: beat&.encoder, busy: beat&.busy == true,
                      remote_nodes: nodes.map { |node| { id: node.id, name: node.name, encoder: node.encoder_kind } } },
        queue: {
          queued: waiting, run_now: queued.where(run_now: true).count,
          manual: queued.where(origin: OptimizedVersion::Origin::Manual.serialize).count,
          interrupted: queued.where(interruptions: 1..).count,
          failed: OptimizedVersion.where(state: OptimizedVersion::State::Failed.serialize).count,
          skipped: OptimizedVersion.where(state: OptimizedVersion::State::Skipped.serialize).count,
          estimated_bytes: estimated_bytes(queued, setting.optimize_max_height)
        },
        budget: { used_bytes: used, budget_bytes: setting.optimize_budget_bytes, full: full },
        encoding: encoding.map { |version| encoding_json(version) }
      }
    end

    sig { params(state: State, waiting: Integer).returns(String) }
    def self.message(state, waiting)
      queue = "#{waiting} waiting"
      case state
      when State::Encoding then waiting.zero? ? "Encoding the last one queued." : "Encoding now, #{waiting} after it."
      when State::Idle then "Nothing is waiting to be optimized."
      when State::NoTranscoder then "The transcoder isn't running, so nothing will be optimized (#{queue}). Start bin/transcoder."
      when State::Paused then "Paused by you: only versions asked for now are encoded (#{queue})."
      when State::WaitingQuietHours then "Waiting for quiet hours (#{queue})."
      when State::OverBudget then "The space for optimized versions is full: only ones you asked for are encoded (#{queue})."
      when State::Busy then "Giving way: someone is watching something that needs converting (#{queue})."
      when State::Starting then "Starting the next one in a few seconds (#{queue})."
      else T.absurd(state)
      end
    end

    # A running encode, with how fast it's going and how long it has left.
    sig { params(version: OptimizedVersion).returns(T::Hash[Symbol, T.untyped]) }
    def self.encoding_json(version)
      duration = version.media_file&.duration_seconds.to_f
      started = version.started_at
      elapsed = started ? (Time.current - started).to_f : 0.0
      progress = version.progress.to_f
      timed = elapsed > 5 && progress >= 0.01
      OptimizedVersionSerializer.row_json(version).merge(
        speed: timed && duration.positive? ? (progress * duration / elapsed).round(2) : nil,
        eta_seconds: timed ? (elapsed * (1 - progress) / progress).round : nil
      )
    end

    # Roughly how much the queue will take once encoded.
    sig { params(queued: T.untyped, max_height: Integer).returns(Integer) }
    def self.estimated_bytes(queued, max_height)
      queue_estimates(queued, max_height).sum(&:last)
    end

    # Each queued version's rough size, in the order they'll be encoded.
    sig { params(queued: T.untyped, max_height: Integer).returns(T::Array[[ String, Integer ]]) }
    def self.queue_estimates(queued, max_height)
      rows = queued.joins(:media_file).in_queue_order.pluck(Arel.sql("optimized_versions.id"), Arel.sql("media_files.duration_seconds"),
        Arel.sql("(SELECT max(s.height) FROM media_streams s WHERE s.media_file_id = media_files.id AND s.kind = 'video')"))
      rows.map do |id, duration, height|
        video = FfmpegArgs.bitrate_for([ height.to_i.nonzero? || max_height, max_height ].min) * 6 / 10
        [ id, ((video + AUDIO_KBPS) * 1000 / 8 * duration.to_f).round ]
      end
    end

    # Whether each queued version will fit in what's left of the budget,
    # taking the queue in order: past it, only what an admin asked for is
    # encoded (Optimizer#claim).
    sig { returns(T::Hash[String, { estimated_bytes: Integer, fits: T::Boolean }]) }
    def self.queue_fit
      setting = AppSetting.cached
      room = setting.optimize_budget_bytes - OptimizedVersion.bytes_used
      manual = OptimizedVersion.queued.where(origin: OptimizedVersion::Origin::Manual.serialize).pluck(:id).to_set
      total = 0
      queue_estimates(OptimizedVersion.queued, setting.optimize_max_height).to_h do |id, bytes|
        total += bytes
        [ id, { estimated_bytes: bytes, fits: manual.include?(id) || total <= room } ]
      end
    end
  end
end

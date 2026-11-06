# typed: strict
# frozen_string_literal: true

# A press of Play as the Playback page shows it: what played, where, how and
# why, and how it went. Rows come from Playback::SessionQuery, which counts
# each session's events in SQL.
module PlaybackDecisionSerializer
  extend T::Sig

  # How many events the detail shows, newest last.
  EVENTS = 200

  sig { params(session: PlaybackSession).returns(T::Hash[Symbol, T.untyped]) }
  def self.row_json(session)
    stalls = session.read_attribute("stalls_count").to_i
    errors = session.read_attribute("errors_count").to_i
    {
      id: session.id, title: Playback::Report.title_for(session.playable), started_at: session.started_at,
      ended_at: session.ended_at, position_seconds: session.position_seconds, state: session.state_enum,
      profile: session.profile && { id: session.profile_id, name: session.profile&.name },
      device: session.device ? { id: session.device_id, name: session.device&.name } : { id: nil, name: session.device_name },
      method: session.method_enum, summary: session.stored_decision.summary, reasons: session.stored_decision.reasons,
      fix_hint: Playback::Report.fix_hint(session.decision), transcode_error: session.transcode_error,
      media_file: session.media_file && { id: session.media_file_id, filename: session.media_file&.filename },
      stalls: stalls, errors: errors, recoveries: session.read_attribute("recoveries_count").to_i,
      startup_ms: session.read_attribute("startup_ms")&.round,
      outcome: outcome(session.transcode_error.present?, errors, stalls)
    }
  end

  # One session in full, for the row's detail: the row (so a session loaded
  # through Playback::SessionQuery), the decision's particulars, and what
  # its player reported, in order.
  sig { params(session: PlaybackSession).returns(T::Hash[Symbol, T.untyped]) }
  def self.detail_json(session)
    events = PlaybackEvent.where(playback_session_id: session.id).order(created_at: :desc).limit(EVENTS).to_a.reverse
    row_json(session).merge(
      decision: session.decision.slice("video", "audio", "container", "refusal"),
      events: events.map do |event|
        { kind: event.kind_enum, at: event.created_at, position_seconds: event.position_seconds, message: event_message(event) }
      end
    )
  end

  sig { params(failed: T::Boolean, errors: Integer, stalls: Integer).returns(PlaybackSession::Outcome) }
  def self.outcome(failed, errors, stalls)
    if failed then PlaybackSession::Outcome::Failed
    elsif errors.positive? then PlaybackSession::Outcome::Errored
    elsif stalls.positive? then PlaybackSession::Outcome::Stalled
    else PlaybackSession::Outcome::Clean
    end
  end

  # An event's particulars in words: an error's message, a timing.
  sig { params(event: PlaybackEvent).returns(T.nilable(String)) }
  def self.event_message(event)
    detail = event.detail
    if detail["message"].present?
      return [ detail["message"], detail["cause"].presence ].compact.join(": ").truncate(400)
    end

    return summary_message(detail) if event.kind_enum == PlaybackEvent::Kind::Summary
    return "#{detail['ms'].to_f.round} ms#{detail['ready'] ? ' (buffered)' : ''}" if detail["ms"].to_s.match?(/\A\d+(\.\d+)?\z/)

    nil
  end

  # "2 stalls, 7 dropped frames, 21 min watched at 4.2 Mb/s, started in 1820 ms".
  sig { params(detail: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
  def self.summary_message(detail)
    parts = []
    parts << "#{detail['stalls'].to_i} stall#{'s' unless detail['stalls'].to_i == 1}" if detail.key?("stalls")
    parts << "#{detail['dropped_frames'].to_i} dropped frame#{'s' unless detail['dropped_frames'].to_i == 1}" if detail.key?("dropped_frames")
    if detail.key?("watched_seconds")
      watched = detail["watched_seconds"].to_f
      watched_words = watched >= 90 ? "#{(watched / 60).round} min watched" : "#{watched.round} s watched"
      watched_words += " at #{(detail['bitrate'].to_f / 1_000_000).round(1)} Mb/s" if detail["bitrate"].to_f.positive?
      parts << watched_words
    end
    parts << "started in #{detail['ms'].to_f.round} ms" if detail["ms"].to_s.match?(/\A\d+(\.\d+)?\z/)
    parts.join(", ").presence
  end
end

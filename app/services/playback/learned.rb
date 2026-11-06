# typed: strict
# frozen_string_literal: true

module Playback
  # What plays have taught about a file on a kind of client,
  # and what a decision should start
  # from because of it. Careful about what it learns from:
  #
  # - only a failure that is the client's or the file's (decode,
  #   unsupported, a transcoder that refused it) teaches; a stall or the
  #   network is about the evening, not the file;
  # - one failure skips that rung for that file on that client class;
  # - a format (Learned.signature) is skipped on a rung only once two
  #   different files of it have failed there, with no success there since;
  # - a file that has played on a rung keeps playing on it, its format
  #   notwithstanding; one client class never teaches another;
  # - every demotion is tried again after Playability::PROBATION.
  module Learned
    extend T::Sig

    # Seconds a rung must play for before it counts as working.
    PLAYED = 30.0

    # The client class of what the server found trying a format itself
    # (PlayabilitySweepJob): evidence for every kind of client.
    SERVER = "server"

    # A file's format, as far as playing it goes: the container, the
    # picture's codec, profile, pixel format and field order, the sound's
    # codec and channels.
    sig { params(file: MediaFile).returns(String) }
    def self.signature(file)
      video = file.media_streams.find { |stream| stream.kind_enum == MediaStream::Kind::Video }
      audio = file.media_streams.find { |stream| stream.kind_enum == MediaStream::Kind::Audio && stream.default } ||
        file.media_streams.find { |stream| stream.kind_enum == MediaStream::Kind::Audio }
      [ file.container, video&.codec, video&.profile, video&.pixel_format, video&.field_order, audio&.codec, audio&.channels ]
        .map { |part| part.to_s.presence || "-" }.join("|")
    end

    # The rung a session played on.
    sig { params(session: PlaybackSession).returns(String) }
    def self.rung(session)
      method = session.method.to_s
      software = session.constraints.software
      software && method == PlaybackSession::Method::VideoTranscode.serialize ? "#{method}_software" : method
    end

    # A session failed on its rung, the way that teaches.
    sig { params(session: PlaybackSession).void }
    def self.failed!(session)
      row = row_for(session)
      return if row.nil?

      row.update!(failures: row.failures + 1, last_failed_at: Time.current, last_failure_class: session.failure_class,
        last_failure_cause: session.failure_cause.to_s.truncate(250).presence)
    end

    # A session has played long enough on its rung: it works here.
    sig { params(session: PlaybackSession).void }
    def self.played!(session)
      row = row_for(session)
      return if row.nil?

      row.update!(successes: row.successes + 1, last_succeeded_at: Time.current)
    end

    # What the sweep found trying a file one way (Playback::Trial).
    sig { params(file: MediaFile, rung: String, outcome: Trial::Outcome, version: String).void }
    def self.tried!(file, rung, outcome, version)
      row = Playability.create_or_find_by!(media_file_id: file.id, client_class: SERVER, rung: rung) do |created|
        created.household_id = file.household_id
        created.format_signature = signature(file)
      end
      if outcome.ok
        row.update!(successes: row.successes + 1, last_succeeded_at: Time.current, version: version)
      else
        row.update!(failures: row.failures + 1, last_failed_at: Time.current, version: version,
          last_failure_class: PlaybackSession::FailureClass::Server.serialize, last_failure_cause: outcome.cause.to_s.truncate(250))
      end
    end

    # The constraints a decision for this file on this client class starts
    # from, and why, in words; none when nothing was learned.
    sig { params(file: MediaFile, client_class: T.nilable(String)).returns([ Constraints, T.nilable(String) ]) }
    def self.constraints_for(file, client_class)
      return [ Constraints::NONE, nil ] if client_class.blank?

      own = Playability.where(media_file_id: file.id, client_class: client_class).index_by(&:rung)
      # What files like this taught this client class and the server, in
      # one query rather than two per rung (Lucid flagged the N+1 on every
      # press of Play: docs/APPLETV_STALLS.md › R5).
      like_this = Playability.where(household_id: file.household_id, format_signature: signature(file), client_class: [ client_class, SERVER ])
        .to_a.group_by { |row| [ row.client_class, row.rung ] }
      lessons = RUNGS.filter_map { |rung| lesson(file, client_class, rung, own[rung], like_this) }
      return [ Constraints::NONE, nil ] if lessons.empty?

      constraints = lessons.reduce(Constraints::NONE) do |now, (rung, failure, _)|
        method = PlaybackSession::Method.deserialize(rung.delete_suffix("_software"))
        Fallback.next_constraints_for(method, now, failure, hardware: !rung.end_with?("_software")) || now
      end
      first = T.must(lessons.first)
      [ constraints, "#{LABELS.fetch(first[0])} #{first[2]} — skipped" ]
    end

    RUNGS = %w[direct remux audio_transcode optimized video_transcode].freeze

    # A rung in the methods' own words, the picture's conversion told
    # apart by where it ran.
    LABELS = T.let(PlaybackSession::Method.values.to_h { |method| [ method.serialize, method.label ] }.merge(
      "video_transcode" => "Converting the picture with hardware", "video_transcode_software" => "Converting the picture"
    ).freeze, T::Hash[String, String])

    # Why this rung is skipped for this file, if it is: its own failure,
    # or its format's.
    sig do
      params(file: MediaFile, client_class: String, rung: String, own: T.nilable(Playability),
        like_this: T::Hash[[ T.nilable(String), T.nilable(String) ], T::Array[Playability]])
        .returns(T.nilable([ String, PlaybackSession::FailureClass, String ]))
    end
    def self.lesson(file, client_class, rung, own, like_this)
      if own&.failing?
        return [ rung, own.failure_class || PlaybackSession::FailureClass::Unsupported, "failed for this file on #{client_class} before" ]
      end
      # It played here: its format's failures don't stand for it.
      return nil if own&.last_succeeded_at

      # The server couldn't play a file like this this way: one witness is
      # enough, since its pipeline is the same for every client.
      server = like_this.fetch([ SERVER, rung ], []).find(&:failing?)
      return [ rung, PlaybackSession::FailureClass::Server, "failed when the server tried a file like this" ] if server

      rows = like_this.fetch([ client_class, rung ], []).reject { |row| row.media_file_id == file.id }
      failing = rows.select(&:failing?)
      return nil if failing.map(&:media_file_id).uniq.size < 2

      latest = failing.filter_map(&:last_failed_at).max
      return nil if latest && rows.any? { |row| (succeeded = row.last_succeeded_at) && succeeded > latest }

      failure = failing.max_by { |row| row.last_failed_at || Time.at(0) }&.failure_class || PlaybackSession::FailureClass::Unsupported
      [ rung, failure, "failed for #{failing.size} files like this on #{client_class}" ]
    end
    private_class_method :lesson

    sig { params(session: PlaybackSession).returns(T.nilable(Playability)) }
    def self.row_for(session)
      file = session.media_file
      client = session.client_class
      return nil if file.nil? || client.blank?

      Playability.create_or_find_by!(media_file_id: file.id, client_class: client, rung: rung(session)) do |row|
        row.household_id = file.household_id
        row.format_signature = signature(file)
      end
    end
    private_class_method :row_for
  end
end

# typed: strict
# frozen_string_literal: true

# The media byte surface (PROPOSAL §3.2, §3.3): authorized by the stream
# token in the path, never by a session, because <video> can't send one.
# Rails checks the token and, for a stream, waits for the transcoder; the
# bytes go out through Thruster via X-Sendfile (CLAUDE.md invariant 7).
class MediaController < ActionController::API
  extend T::Sig
  include SendsMedia

  before_action :set_session

  # How often a playing stream refreshes last_seen_at: enough for the
  # transcoder's idle check, few enough writes.
  SEEN_EVERY = T.let(15.seconds, ActiveSupport::Duration)

  sig { void }
  def original
    return optimized if session!.method_enum == PlaybackSession::Method::Optimized

    path = session!.media_file&.servable_path&.to_s
    return head(:not_found) if path.nil?

    mime = direct? ? mime_for(path) : "application/octet-stream"
    count(path)
    serve(path, mime)
  end

  # The master playlist when the stream has smaller versions (adaptive
  # bitrate), else the one media playlist. A version's own playlist, init
  # and segments are under v<n>/.
  sig { void }
  def playlist
    return head(:not_found) if direct? || live? || variant.nil?

    touch
    response.headers["Cache-Control"] = "no-cache"
    master = params[:variant].nil? ? Playback::Segments.master(session!) : nil
    render plain: master || Playback::Segments.new(session!, T.must(variant)).playlist, content_type: "application/vnd.apple.mpegurl"
  end

  sig { void }
  def init
    return head(:not_found) if direct? || live? || variant.nil?

    remaking_if_gone do
      init = Playback::Segments.new(session!, T.must(variant), gone: -> { client_gone? }).init
      count(init, later: true)
      keep_for_the_session
      serve(init, "video/mp4")
    end
  rescue Playback::Segments::Abandoned, Playback::Segments::Ended => e
    let_go(e)
  rescue Playback::Segments::Unavailable => e
    unavailable(e)
  end

  sig { void }
  def segment
    return head(:not_found) if direct? || live? || variant.nil?

    touch
    remaking_if_gone do
      segment = Playback::Segments.new(session!, T.must(variant), gone: -> { client_gone? }).segment(params[:index].to_i)
      count(segment, later: true)
      keep_for_the_session
      serve(segment, "video/iso.segment")
    end
  rescue Playback::Segments::Abandoned, Playback::Segments::Ended => e
    let_go(e)
  rescue Playback::Segments::Unavailable => e
    unavailable(e)
  end

  SUBTITLE_TYPES = T.let({ "vtt" => "text/vtt", "ass" => "text/x-ssa", "sup" => "application/octet-stream" }.freeze,
    T::Hash[String, String])

  # How long a pick of a track not taken out yet waits on its job before
  # being told to ask again: a Puma thread, not half an hour of one. The job
  # takes minutes when it isn't over at once, and both players ask again for
  # fifteen, so waiting longer only holds the thread.
  SUBTITLE_WAIT = 3.0
  SUBTITLE_RETRY_AFTER = 10

  # A subtitle track in the format the player renders it in (PROPOSAL
  # §5.5). Taken out of the file by the one read over it (Media::OnePass);
  # a track that read hasn't reached yet is taken out by a job of its own,
  # waited on a moment, then answered 503 with Retry-After — the players
  # ask again (docs/APPLETV_STALLS.md › R5). It used to be read here, in
  # the request: a PGS track off a slow share held a thread 31 minutes.
  sig { void }
  def subtitle
    file = session!.media_file
    return head(:not_found) if file.nil?

    extension = params[:format].to_s
    track = Subtitles::Tracks.find(file, params[:track].to_s)
    return head(:not_found) if track.nil? || !Subtitles::Extractor.extensions_for(track).include?(extension)

    path = Subtitles::Extractor.path_for(file, track, extension)
    unless path.file?
      failure = Subtitles::Extractor.failed(file, track, extension)
      return subtitle_failed(failure) if failure

      ExtractSubtitleTrackJob.perform_later(file.id, track.id, extension)
      Playback::Wait.until(SUBTITLE_WAIT, every: 0.25, gone: -> { client_gone? }) do
        path.file? || !Subtitles::Extractor.failed(file, track, extension).nil?
      end
      unless path.file?
        failure = Subtitles::Extractor.failed(file, track, extension)
        return subtitle_failed(failure) if failure

        response.headers["Retry-After"] = SUBTITLE_RETRY_AFTER.to_s
        return render(plain: "The subtitles are still being taken out of the file", status: :service_unavailable)
      end
    end

    response.headers["Cache-Control"] = "private, max-age=3600"
    serve(path, T.must(SUBTITLE_TYPES[extension]))
  end

  # One seek-bar thumbnail sheet (PROPOSAL §7.3). Versioned in the path, so
  # it can be cached for as long as the session lives.
  sig { void }
  def trickplay
    trickplay = session!.media_file&.trickplay
    version = params[:version].to_i
    index = params[:index].to_i
    return head(:not_found) if trickplay.nil? || trickplay.version != version || !index.between?(0, trickplay.sheet_count - 1)

    response.headers["Cache-Control"] = "private, max-age=86400, immutable"
    serve(trickplay.sheet(index), "image/webp")
  end

  # A font embedded in the file, for styled subtitles.
  sig { void }
  def font
    file = session!.media_file
    return head(:not_found) if file.nil?

    font = Subtitles::Extractor.fonts(file).find { |path| path.basename.to_s == params[:name].to_s }
    return head(:not_found) if font.nil?

    response.headers["Cache-Control"] = "private, max-age=86400"
    serve(font, "font/#{font.extname.delete('.').presence || 'ttf'}")
  end

  # Timed reports while playing, and one from sendBeacon as the tab closes —
  # which is why this lives here, authorized by the token, rather than
  # under /api where it would need a header a beacon can't send.
  sig { void }
  def progress
    body = request.content_type.to_s.include?("json") ? params : parse_beacon
    position = T.let(Float(body[:position].to_s, exception: false), T.nilable(Float))
    return head(:bad_request) if position.nil?

    ended = body[:ended].to_s == "true"
    state = Playback::Progress.report(session!, position: position, ended: ended)
    record_event(PlaybackEvent::Kind::Stop, position, {}) if ended
    return render json: { position_seconds: position, completed: false, relay: relay_json } if state.nil?

    Trakt::Scrobbler.observe(session!, state, ended: ended)
    render json: { position_seconds: state.position_seconds, completed: state.completed? }
  end

  # How long a live playlist request waits for a relay that's starting:
  # the first segment needs the source's next keyframe after it connects.
  LIVE_WAIT = 20.0

  # A live stream's playlist (PROPOSAL §7.8), as its relay last wrote it.
  # Every fetch says someone's watching (LiveCache.want!) and asks for the
  # relay (a no-op when it's running); the first waits for its first
  # segment. Served from Rails: it's a few hundred bytes, and rewritten
  # every segment.
  sig { void }
  def live_playlist
    return head(:not_found) unless live? && session!.active?

    key = Playback::LiveCache.key_for(session!)
    Playback::LiveCache.want!(key)
    touch
    Playback::Signal.relay(session!.id)
    outcome = Playback::Wait.until(LIVE_WAIT, every: 0.2, gone: -> { client_gone? }) { Playback::LiveCache.ready?(key) }
    return let_go(Playback::Segments::Abandoned.new) if outcome == Playback::Wait::Outcome::Abandoned

    if outcome == Playback::Wait::Outcome::TimedOut
      status = Playback::LiveCache.status(key)
      return render(plain: status&.message || "The stream didn't start in time", status: :service_unavailable)
    end

    response.headers["Cache-Control"] = "no-cache"
    render plain: File.read(Playback::LiveCache.playlist(key)), content_type: "application/vnd.apple.mpegurl"
  rescue SystemCallError
    head :service_unavailable
  end

  # Its init segment and segments, by the names the playlist gives them.
  # The init segment is written again by a relay that reconnects; a
  # segment's name is never reused (LiveArgs), so it can be kept.
  sig { void }
  def live_file
    return head(:not_found) unless live?

    name = "#{params[:name]}.#{params[:ext]}"
    path = Playback::LiveCache.file(Playback::LiveCache.key_for(session!), name)
    return head(:not_found) if path.nil?

    response.headers["Cache-Control"] = name == "init.mp4" ? "no-cache" : "private, max-age=3600, immutable"
    count(path, later: true)
    serve(path, name == "init.mp4" ? "video/mp4" : "video/iso.segment")
  end

  # What a player may say about an event: an error's words, a stall's
  # length, and how long a start, a seek or a channel change took (and
  # where that time went).
  EVENT_DETAIL = T.let(%w[message cause code count seconds ms ready session_ms manifest_ms init_ms fragment_ms frame_ms via
    stalls dropped_frames watched_seconds bitrate].freeze, T::Array[String])

  # What the player saw: stalls and errors, and how long starting and
  # seeking took, for the Playback decisions page.
  sig { void }
  def events
    Array(params[:events]).first(20).each do |event|
      kind = PlaybackEvent::Kind.try_deserialize(event[:kind].to_s)
      next if kind.nil? || [ PlaybackEvent::Kind::Start, PlaybackEvent::Kind::Stop ].include?(kind)

      detail = event[:detail].respond_to?(:to_unsafe_h) ? event[:detail].to_unsafe_h.slice(*EVENT_DETAIL) : {}
      record_event(kind, T.let(Float(event[:position].to_s, exception: false), T.nilable(Float)), detail)
    end
    head :no_content
  end

  private

  sig { void }
  def set_session
    @session = T.let(Playback::StreamToken.verify(params[:token].to_s), T.nilable(PlaybackSession))
    head :not_found if @session.nil?
  end

  sig { returns(PlaybackSession) }
  def session! = T.must(@session)

  sig { returns(T::Boolean) }
  def direct? = !session!.method_enum.streamed?

  sig { returns(T::Boolean) }
  def live? = session!.playable_type == "LiveStream"

  # How a live stream's relay is going, for its player to say.
  sig { returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def relay_json
    return nil unless live?

    status = Playback::LiveCache.status(Playback::LiveCache.key_for(session!))
    status && { state: status.state, message: status.message }
  end

  # What this request sends (PROPOSAL §7.4): the range asked for, else the
  # whole file — counted here because the bytes themselves go out through
  # Thruster, where Rails never sees them.
  #
  # A stream's init and segments are added up in memory and written with
  # the next touch; a file's range requests are few, and written at once.
  sig { params(path: T.any(String, Pathname), later: T::Boolean).void }
  def count(path, later: false)
    bytes = Playback::BytesSent.of_request(request.headers["Range"].to_s, File.size(path))
    if later
      Playback::BytesSent.add(session!.id, bytes)
    else
      PlaybackSession.update_counters(session!.id, bytes_sent: bytes) # rubocop:disable Rails/SkipsModelValidations
    end
  rescue SystemCallError
    nil
  end

  # Which version: the original unless the path says v<n>; nil for one
  # this stream doesn't have.
  sig { returns(T.nilable(Integer)) }
  def variant
    index = params[:variant].to_i
    return 0 if index.zero?

    Playback::Variants.find(session!, index) ? index : nil
  end

  # The optimized version the decision chose, from the cache volume.
  sig { void }
  def optimized
    version = OptimizedVersion.unscoped.find_by(id: session!.stored_decision.optimized_version_id,
      media_file_id: session!.media_file_id)
    return head(:not_found) if version.nil? || !version.ready?

    count(version.path)
    serve(version.path, "video/mp4")
  end

  # The player dropped this request (a seek moved on): Thruster drops its
  # connection to Puma with it.
  sig { returns(T::Boolean) }
  def client_gone? = Playback::ClientGone.gone?(request.env["puma.socket"])

  sig { void }
  def touch
    seen = session!.last_seen_at
    return unless seen.nil? || seen < SEEN_EVERY.ago

    session!.update_columns(last_seen_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    Playback::BytesSent.flush(session!.id)
  end

  # A stream's init and segments never change under their path, which is
  # unique to its session — a GOP is published once, whichever run made it
  # first (Playback::Publisher): the browser can keep them, so seeking back
  # is served from its own cache (docs/PERF_PROPOSAL.md › P13).
  sig { void }
  def keep_for_the_session
    response.headers["Cache-Control"] = "private, max-age=#{Playback::StreamToken::LIFETIME.to_i}, immutable"
  end

  sig { params(path: String).returns(String) }
  def mime_for(path) = File.extname(path).casecmp?(".webm") ? "video/webm" : "video/mp4"

  # Swept from the cache between being found and being sent: made once more,
  # as the transcoder makes any segment it hasn't yet.
  sig { params(block: T.proc.void).void }
  def remaking_if_gone(&block)
    block.call
  rescue Gone
    block.call
  end

  # Nobody to tell, and nothing went wrong: no error recorded, and no 5xx
  # for something nobody is waiting for. 499 (client closed the request) when
  # the player hung up; 410 when its session ended under the wait.
  sig { params(error: Playback::Segments::Unavailable).void }
  def let_go(error)
    error.is_a?(Playback::Segments::Ended) ? head(:gone) : head(499)
  end

  sig { params(message: String).void }
  def subtitle_failed(message)
    record_event(PlaybackEvent::Kind::Error, nil, { "message" => "subtitle #{params[:track]}: #{message}".truncate(300) })
    render plain: message, status: :unprocessable_content
  end

  # 503 for a segment that wasn't made in time (the player asks again);
  # 424 when the transcoder has given up on this session (Failed) — a 4xx,
  # which hls.js doesn't retry, so the player falls back a rung at once.
  sig { params(error: Playback::Segments::Unavailable).void }
  def unavailable(error)
    record_event(PlaybackEvent::Kind::Error, nil, { "message" => error.message.truncate(300) })
    render plain: error.message, status: error.is_a?(Playback::Segments::Failed) ? :failed_dependency : :service_unavailable
  end

  sig { params(kind: PlaybackEvent::Kind, position: T.nilable(Float), detail: T::Hash[String, T.untyped]).void }
  def record_event(kind, position, detail)
    PlaybackEvent.create!(playback_session: session!, kind: kind.serialize, position_seconds: position, detail: detail,
      created_at: Time.current)
  end

  # sendBeacon posts text/plain; its body is still our JSON.
  sig { returns(ActiveSupport::HashWithIndifferentAccess) }
  def parse_beacon
    parsed = JSON.parse(request.raw_post.presence || "{}")
    (parsed.is_a?(Hash) ? parsed : {}).with_indifferent_access
  rescue JSON::ParserError
    ActiveSupport::HashWithIndifferentAccess.new
  end
end

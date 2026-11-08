# typed: strict
# frozen_string_literal: true

# A subtitle track in a format a player renders (PROPOSAL §5.5), for any
# token-in-the-path surface: a playing session's (/media/s) and an offline
# download's (/media/d). Taken out of the file by the one read over it
# (Media::OnePass); a track that read hasn't reached yet is taken out by a
# job of its own, waited on a moment, then answered 503 with Retry-After —
# the players ask again (docs/APPLETV_STALLS.md › R5). It is never read in
# the request: a PGS track off a slow share held a Puma thread 31 minutes
# (CLAUDE.md invariant 7).
module ServesSubtitles
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ActionController::API }

  include SendsMedia

  # How long a pick of a track not taken out yet waits on its job before
  # being told to ask again: a Puma thread, not half an hour of one. The job
  # takes minutes when it isn't over at once, and the players ask again, so
  # waiting longer only holds the thread.
  SUBTITLE_WAIT = 3.0
  SUBTITLE_RETRY_AFTER = 10

  SUBTITLE_TYPES = T.let({ "vtt" => "text/vtt", "ass" => "text/x-ssa", "sup" => "application/octet-stream" }.freeze,
    T::Hash[String, String])

  private

  # Serves the track once it's out; `failed` answers why it couldn't be
  # taken out (the caller may record it too).
  sig do
    params(file: MediaFile, track: Subtitles::Tracks::Track, extension: String,
      failed: T.proc.params(message: String).void).void
  end
  def serve_subtitle(file, track, extension, failed:)
    path = Subtitles::Extractor.path_for(file, track, extension)
    unless path.file?
      failure = Subtitles::Extractor.failed(file, track, extension)
      return failed.call(failure) if failure

      ExtractSubtitleTrackJob.perform_later(file.id, track.id, extension)
      Playback::Wait.until(SUBTITLE_WAIT, every: 0.25, gone: -> { client_gone? }) do
        path.file? || !Subtitles::Extractor.failed(file, track, extension).nil?
      end
      unless path.file?
        failure = Subtitles::Extractor.failed(file, track, extension)
        return failed.call(failure) if failure

        response.headers["Retry-After"] = SUBTITLE_RETRY_AFTER.to_s
        return render(plain: "The subtitles are still being taken out of the file", status: :service_unavailable)
      end
    end

    response.headers["Cache-Control"] = "private, max-age=3600"
    serve(path, T.must(SUBTITLE_TYPES[extension]))
  end

  # The player dropped this request (a seek moved on): Thruster drops its
  # connection to Puma with it.
  sig { returns(T::Boolean) }
  def client_gone? = Playback::ClientGone.gone?(request.env["puma.socket"])
end

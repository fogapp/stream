# typed: strict
# frozen_string_literal: true

# What an offline download fetches (/media/d/<token>/…): the file and its
# text subtitles, authorized by the download token in the path, since a
# background fetch sends no header. The bytes go out through X-Sendfile, and
# a subtitle not taken out yet is a 503 to ask again (ServesSubtitles).
class DownloadMediaController < ActionController::API
  extend T::Sig
  include SendsMedia
  include ServesSubtitles

  before_action :set_download

  sig { void }
  def file
    path = download!.source_path
    return head(:not_found) if path.nil? || params[:ext].to_s != download!.extension

    serve(path, download!.mime_type)
  end

  # A text track as WebVTT: out of the file already, or taken out by a job
  # and asked for again — never read in the request (ServesSubtitles).
  sig { void }
  def subtitle
    file = T.must(download!.media_file)
    track = Subtitles::Tracks.find(file, params[:track].to_s)
    return head(:not_found) if track.nil? || !Subtitles::Extractor.extensions_for(track).include?("vtt")

    serve_subtitle(file, track, "vtt", failed: ->(message) { render plain: message, status: :unprocessable_content })
  end

  private

  sig { void }
  def set_download
    @download = T.let(Playback::DownloadToken.verify(params[:token].to_s), T.nilable(OfflineDownload))
    head :not_found if @download.nil?
  end

  sig { returns(OfflineDownload) }
  def download! = T.must(@download)
end

# typed: strict
# frozen_string_literal: true

# The original a remote transcoder's ffmpeg reads (/media/n/<token>/source):
# authorized by the run token in the path, since ffmpeg sends no header, and
# only while the run is live. Range requests make its seeks work; the bytes
# go out through X-Sendfile like any other media.
class NodeMediaController < ActionController::API
  extend T::Sig
  include SendsMedia

  sig { void }
  def source
    path = Playback::RunToken.verify(params[:token].to_s)&.media_file&.servable_path
    return head(:not_found) if path.nil?

    serve(path.to_s, "application/octet-stream")
  end
end

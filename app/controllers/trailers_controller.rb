# typed: strict
# frozen_string_literal: true

# A trailer's file (PROPOSAL §7.1–7.2), fetched by <video>: a signed URL
# like artwork's, no session. The bytes go through X-Sendfile.
class TrailersController < ActionController::API
  extend T::Sig
  include SendsMedia

  sig { void }
  def show
    id = params[:id].to_s
    return head(:not_found) unless Trailers.valid?(id, params[:signature].to_s)

    trailer = Trailer.unscoped.find_by(id: id)
    return head(:not_found) if trailer.nil? || !trailer.ready?

    response.headers["Cache-Control"] = "private, max-age=86400"
    serve(trailer.path, "video/mp4")
  end
end

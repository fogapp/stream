# typed: strict
# frozen_string_literal: true

# A live stream's card picture (LiveStreams::Still), for an <img>: Rails
# checks the signature, Thruster sends the bytes (CLAUDE.md invariant 7).
class LiveStillsController < ActionController::API
  extend T::Sig
  include SendsMedia

  sig { void }
  def show
    version = T.let(Integer(params[:version].to_s, exception: false), T.nilable(Integer))
    id = params[:id].to_s
    return head(:not_found) if version.nil? || !LiveStreams::StillUrl.valid?(id, version, params[:s].to_s)

    path = LiveStreams::Still.path(id)
    return head(:not_found) unless path.file?

    # The signature covers the moment it was taken; the file may be newer.
    response.headers["Cache-Control"] = "private, max-age=86400, immutable"
    serve(path, "image/webp")
  end
end

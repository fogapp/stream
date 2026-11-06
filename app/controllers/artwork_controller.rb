# typed: strict
# frozen_string_literal: true

# Serves rendered artwork (PROPOSAL §3.2): Rails checks the signature and
# answers with X-Sendfile, Thruster sends the bytes. Outside /api, because
# the browser fetches these itself with no bearer token.
class ArtworkController < ActionController::API
  extend T::Sig

  sig { void }
  def show
    version = T.let(Integer(params[:version].to_s, exception: false), T.nilable(Integer))
    width = T.let(Integer(params[:width].to_s, exception: false), T.nilable(Integer))
    id = params[:id].to_s
    return head(:not_found) if version.nil? || width.nil? || !ArtworkUrl.valid?(id, version, params[:s].to_s)

    artwork = Artwork.find_by(id: id, version: version)
    return head(:not_found) if artwork.nil? || !artwork.rendered_widths.include?(width)

    path = artwork.file_for(width)
    return head(:not_found) unless path.file?

    response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
    send_file path, type: "image/webp", disposition: "inline"
  end
end

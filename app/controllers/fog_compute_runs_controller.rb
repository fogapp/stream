# typed: strict
# frozen_string_literal: true

# What a machine working for one of fog's transcoders reaches, through
# fog's data route (fog:docs/compute-contract.md): a run's original, and
# the place its outputs go. Authorized by the run token in the path, like
# /media/n, and only while the run is live; fog's route forwards nothing
# else of Stream's.
class FogComputeRunsController < ActionController::API
  extend T::Sig
  include SendsMedia

  # GET /fog/compute/runs/:token/source
  sig { void }
  def source
    path = Playback::RunToken.verify(params[:token].to_s)&.media_file&.servable_path
    return head(:not_found) if path.nil?

    serve(path.to_s, "application/octet-stream")
  end

  # PUT /fog/compute/runs/:token/files/:name — a fragment, init segment or
  # optimized version, stored as a worker's upload is.
  sig { void }
  def upload
    run = Playback::RunToken.verify(params[:token].to_s)
    return head(:not_found) if run.nil?

    stored = Playback::NodeLink.store(run, params[:name].to_s, request.body, size: request.content_length.to_i)
    head(stored ? :no_content : :unprocessable_content)
  end
end

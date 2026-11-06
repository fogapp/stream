# typed: strict
# frozen_string_literal: true

# fog-compute/1 (fog:docs/compute-contract.md): fog offers Stream each pool
# of machines paired with it as one remote transcoder, and relays its runs
# to whichever machine has room. Outside the console auth stack like
# FogController, authenticated by FOG_API_TOKEN; fog is the only caller.
# The machines themselves reach only the run-signed surface below
# (FogComputeRunsController), through fog's data route.
class FogComputeController < ActionController::API
  extend T::Sig
  include FogContractAuth

  # POST /fog/compute/transcoders {pool, name, hello} — the same transcoder
  # for the same pool, however often fog asks.
  sig { void }
  def create
    pool = params[:pool].to_s
    return render_errors("a pool is required") if pool.blank? || pool.length > 80

    node = TranscodeNode.for_fog_pool(pool, name: params[:name].to_s.presence || "fog · #{pool}")
    hello = params[:hello]
    Playback::NodeLink.introduce!(node, hello.to_unsafe_h) if hello.respond_to?(:to_unsafe_h)
    render json: { id: node.id }
  end

  # DELETE /fog/compute/transcoders/:id — the operator took the pool away.
  sig { void }
  def destroy
    node = TranscodeNode.fog.find_by(id: params[:id].to_s)
    return head(:not_found) if node.nil?

    node.destroy!
    head :no_content
  end

  # POST /fog/compute/transcoders/:id/poll — fog, as the transcoder.
  sig { void }
  def poll
    node = TranscodeNode.fog.find_by(id: params[:id].to_s)
    return head(:not_found) if node.nil?

    raw = JSON.parse(request.raw_post.presence || "{}")
    return head(:bad_request) unless raw.is_a?(Hash)

    render json: Playback::NodeLink.poll_fog(node, Playback::NodeLink.parse(raw), raw)
  rescue JSON::ParserError
    head :bad_request
  end

  private

  sig { params(message: String).void }
  def render_errors(message)
    render json: { errors: [ message ] }, status: :unprocessable_content
  end
end

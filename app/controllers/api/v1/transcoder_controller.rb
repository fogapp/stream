# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # What a remote transcoder's worker talks to (PROPOSAL §11 Phase 6),
    # authenticated by its node token rather than a person's session.
    class TranscoderController < ActionController::API
      extend T::Sig
      include BearerToken

      before_action :authenticate_node!, except: :worker

      sig { void }
      def poll
        raw = JSON.parse(request.raw_post.presence || "{}")
        return head(:bad_request) unless raw.is_a?(Hash)

        render json: Playback::NodeLink.poll(node!, Playback::NodeLink.parse(raw))
      rescue JSON::ParserError
        head :bad_request
      end

      # A finished file from a run: a GOP fragment or init segment of a
      # session, straight into the cache the web side serves segments from,
      # or an optimized version's whole output. Written aside and renamed,
      # so nothing ever reads half of one.
      sig { void }
      def upload
        run = node!.transcode_runs.live.find_by(id: params[:id].to_s)
        return head(:not_found) if run.nil?

        stored = Playback::NodeLink.store(run, params[:name].to_s, request.body, size: request.content_length.to_i)
        head(stored ? :no_content : :unprocessable_content)
      end

      # The worker itself, for `curl … | ruby` on the machine that will run
      # it. Public: it's the same file as bin/stream-transcode-worker.
      sig { void }
      def worker
        send_file Rails.root.join("bin/stream-transcode-worker"), type: "text/x-ruby", disposition: "attachment",
          filename: "stream-transcode-worker"
      end

      private

      sig { void }
      def authenticate_node!
        @node = T.let(TranscodeNode.authenticate(bearer_token), T.nilable(TranscodeNode))
        head :unauthorized if @node.nil?
      end

      sig { returns(TranscodeNode) }
      def node! = T.must(@node)
    end
  end
end

# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Settings › Transcoders (PROPOSAL §11 Phase 6): the machines besides
    # this one that convert video. Admins only; a node's token is shown
    # once, when it's added.
    class TranscodeNodesController < BaseController
      before_action :require_admin!
      finds :transcode_node, from: -> { TranscodeNode.all }
      skip_before_action :set_transcode_node, only: %i[index create]

      sig { void }
      def index
        render json: {
          nodes: TranscodeNodeSerializer.index(TranscodeNode.order(:created_at).to_a),
          local: { encoder: Playback::Encoders.kind, cap: Playback::Encoders.cap },
          capacity: Playback::Placement.capacity
        }
      end

      sig { void }
      def create
        name = params[:name].to_s.strip
        return render_errors("Give it a name, like the machine it runs on") if name.blank?

        generated = TranscodeNode.generate(name: name.first(80))
        Activity.record(source: "playback", event: "transcoder.added", summary: "#{current_user!.name} added the transcoder #{name}")
        render json: TranscodeNodeSerializer.json(generated.node).merge(token: generated.token), status: :created
      end

      sig { void }
      def update
        node = transcode_node
        node.name = params[:name].to_s.strip.first(80) if params[:name].present?
        node.enabled = bool_param(:enabled) if params.key?(:enabled)
        node.optimize = bool_param(:optimize) if params.key?(:optimize)
        if params.key?(:max_sessions)
          return render_errors("fog sets this transcoder's room from its machines") if node.fog?

          sessions = params[:max_sessions].to_i
          return render_errors("Between 1 and 8 videos at once") unless sessions.between?(1, 8)

          node.max_sessions = sessions
        end
        node.save!
        render json: TranscodeNodeSerializer.json(node)
      end

      # Its sessions carry on here from their next segment.
      sig { void }
      def destroy
        transcode_node.destroy!
        Activity.record(source: "playback", event: "transcoder.removed",
          summary: "#{current_user!.name} removed the transcoder #{transcode_node.name}")
        head :no_content
      end
    end
  end
end

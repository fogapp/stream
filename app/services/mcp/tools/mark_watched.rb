# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class MarkWatched < Base
      tool_name "mark_watched"
      title "Mark watched"
      description "Marks a film, episode or video (kind and id) watched — or, with watched: false, unwatched — for a profile."
      input_schema(
        properties: {
          kind: { type: "string", enum: KINDS }, id: { type: "string" }, watched: { type: "boolean", description: "Default true." },
          profile: PROFILE_ARGUMENT
        },
        required: %w[kind id]
      )
      annotations(title: "Mark watched", read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      sig do
        params(kind: T.untyped, id: T.untyped, server_context: T.untyped, watched: T.untyped, profile: T.untyped, _extra: T.untyped)
          .returns(MCP::Tool::Response)
      end
      def self.call(kind:, id:, server_context:, watched: true, profile: nil, **_extra)
        as_profile(server_context, profile) do |viewer|
          playable = find_playable(kind, id)
          raise NotFound, "A camera or stream is live; there's nothing to mark watched." if playable.is_a?(LiveStream)

          state = Playback::Progress.mark(viewer, playable, watched: watched != false)
          json_response(title: playable_json(playable), profile: viewer.name, watched: state.completed?)
        end
      rescue NotFound => e
        failure(e.message)
      end
    end
  end
end

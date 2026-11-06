# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class AddToWatchLater < Base
      SAVEABLE = T.let(%w[movie episode video].freeze, T::Array[String])

      tool_name "add_to_watch_later"
      title "Save to Watch later"
      description "Adds a film, episode or video (kind and id, from search) to a profile's Watch later list."
      input_schema(
        properties: { kind: { type: "string", enum: SAVEABLE }, id: { type: "string" }, profile: PROFILE_ARGUMENT },
        required: %w[kind id]
      )
      annotations(title: "Save to Watch later", read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      sig do
        params(kind: T.untyped, id: T.untyped, server_context: T.untyped, profile: T.untyped, _extra: T.untyped)
          .returns(MCP::Tool::Response)
      end
      def self.call(kind:, id:, server_context:, profile: nil, **_extra)
        as_profile(server_context, profile) do |viewer|
          playable = find_playable(kind, id)
          next failure("Only films, episodes and videos go in Watch later.") unless playable.is_a?(Movie) || playable.is_a?(Episode) || playable.is_a?(Video)

          Playlist.watch_later_for(viewer).add!(playable)
          json_response(saved: playable_json(playable), profile: viewer.name)
        end
      rescue NotFound => e
        failure(e.message)
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class LiveStreams < Base
      tool_name "live_streams"
      title "Cameras and web streams"
      description "The household's cameras and web streams (PROPOSAL §7.8) a profile may see: each one's name, " \
        "kind, whether it's answering, and when it was last seen. play_on_screen puts one on a screen by name."
      input_schema(properties: { profile: PROFILE_ARGUMENT })
      annotations(title: "Cameras and web streams", read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      sig { override.returns(T::Boolean) }
      def self.read_only? = true

      sig { params(server_context: T.untyped, profile: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, profile: nil, **_extra)
        context_household(server_context)
        as_profile(server_context, profile) do
          json_response(Viewing::Access.live_streams(LiveStream.added).order(:sort_title).map do |stream|
            { id: stream.id, name: stream.name, kind: stream.kind, status: stream.status, last_seen_at: stream.last_seen_at&.iso8601,
              description: stream.description }
          end)
        end
      rescue NotFound => e
        failure(e.message)
      end
    end
  end
end

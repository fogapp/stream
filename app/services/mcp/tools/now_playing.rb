# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class NowPlaying < Base
      tool_name "now_playing"
      title "What's playing"
      description "Everything being watched in the household right now: what, by which profile, on which device, and how far in."
      input_schema(properties: {})
      annotations(title: "What's playing", read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      sig { override.returns(T::Boolean) }
      def self.read_only? = true

      sig { params(server_context: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, **_extra)
        context_household(server_context)
        # Every profile's watching, so an admin's, as on the Stats page.
        return failure("Only an admin can see what everyone in the household is watching.") unless context_user(server_context).admin?

        json_response(Stats::Watching.now_playing.map do |row|
          row.slice(:title, :subtitle, :device, :method, :position_seconds, :duration_seconds).merge(profile: row.dig(:profile, :name))
        end)
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class ListScreens < Base
      tool_name "list_screens"
      title "Screens"
      description "The screens that can be played to right now (a TV browser on Stream's /tv, or any browser that " \
        "allows it), and what each is playing."
      input_schema(properties: {})
      annotations(title: "Screens", read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      sig { override.returns(T::Boolean) }
      def self.read_only? = true

      sig { params(server_context: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, **_extra)
        household = context_household(server_context)
        json_response(Device.unscoped.where(household_id: household.id).listening.map { |device| screen_json(device) })
      end

      sig { params(device: Device).returns(T::Hash[Symbol, T.untyped]) }
      def self.screen_json(device)
        session = Remote::Control.now_playing(device)
        { name: device.display_name, browser: device.name,
          now_playing: session && playable_json(session.playable).merge(position_seconds: session.position_seconds.round,
            profile: session.profile&.name) }
      end
    end
  end
end

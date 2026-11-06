# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class TuneChannel < Base
      tool_name "tune_channel"
      title "Put a channel on"
      description "Puts a Grid channel on a listening screen, joining whatever is airing where live is " \
        "(e.g. \"put NBC on in the living room\"). The channel by number or name, as whats_on lists them."
      input_schema(
        properties: {
          channel: { type: "string", description: "The channel's number (\"4\") or name (\"NBC\")." },
          screen: { type: "string", description: "The screen's name; may be left out when only one is listening." },
          profile: PROFILE_ARGUMENT
        },
        required: [ "channel" ]
      )
      annotations(title: "Put a channel on", read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: false)

      sig do
        params(server_context: T.untyped, channel: T.untyped, screen: T.untyped, profile: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response)
      end
      def self.call(server_context:, channel:, screen: nil, profile: nil, **_extra)
        user = context_user(server_context)
        as_profile(server_context, profile) do |viewer|
          station = find_station(Viewing::Access.stations(Station.in_order).to_a, channel)
          device = Remote::Control.find_device(screen&.to_s)
          Remote::Control.tune(device, station, profile: viewer, user: user)
          json_response(channel: "#{station.number} #{station.name}", screen: device.display_name, profile: viewer.name,
            note: "The screen picks it up within a few seconds.")
        end
      rescue NotFound, Remote::Control::Error => e
        failure(e.message)
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class ControlScreen < Base
      tool_name "control_screen"
      title "Pause, resume, seek or stop"
      description "Pauses, resumes, stops, or seeks what a listening screen is playing. Seek takes `seconds` " \
        "(a position) or `by` (plus or minus, e.g. -30 to go back half a minute)."
      input_schema(
        properties: {
          screen: { type: "string", description: "The screen's name; may be left out when only one is listening." },
          action: { type: "string", enum: %w[pause resume stop seek] },
          seconds: { type: "number" }, by: { type: "number" }
        },
        required: %w[action]
      )
      annotations(title: "Pause, resume, seek or stop", read_only_hint: false, destructive_hint: false, idempotent_hint: false,
        open_world_hint: false)

      sig do
        params(action: T.untyped, server_context: T.untyped, screen: T.untyped, seconds: T.untyped, by: T.untyped, _extra: T.untyped)
          .returns(MCP::Tool::Response)
      end
      def self.call(action:, server_context:, screen: nil, seconds: nil, by: nil, **_extra)
        kind = DeviceCommand::Kind.try_deserialize(action.to_s)
        return failure("The action is pause, resume, stop or seek.") if kind.nil? || kind == DeviceCommand::Kind::Play
        return failure("Seek needs seconds or by.") if kind == DeviceCommand::Kind::Seek && seconds.nil? && by.nil?

        device = Remote::Control.find_device(screen&.to_s)
        payload = { "seconds" => seconds&.to_f, "by" => by&.to_f }.compact
        Remote::Control.send_command(device, kind, payload, user: context_user(server_context))
        json_response(screen: device.display_name, action: kind.serialize, **payload.symbolize_keys)
      rescue Remote::Control::Error => e
        failure(e.message)
      end
    end
  end
end

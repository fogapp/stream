# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class Whoami < Base
      tool_name "whoami"
      title "Who am I"
      description "The household and the person this token belongs to, the household's profiles (whose watch " \
        "history counts), and the screens listening right now that can be played to."
      input_schema(properties: {})
      annotations(title: "Who am I", read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      sig { override.returns(T::Boolean) }
      def self.read_only? = true

      sig { params(server_context: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, **_extra)
        user = context_user(server_context)
        household = context_household(server_context)
        default = Profile.open_default_for(household)
        json_response(
          household: household.name, user: { name: user.name, role: user.role },
          profiles: Profile.unscoped.where(household_id: household.id).order(:position, :created_at).map do |profile|
            { name: profile.name, kid: profile.kid?, pin: profile.pin?, default: profile.id == default.id }
          end,
          screens: ListScreens.screens_json(Device.unscoped.where(household_id: household.id).listening.to_a)
        )
      end
    end
  end
end

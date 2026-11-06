# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class PlayOnScreen < Base
      tool_name "play_on_screen"
      title "Play on a screen"
      description "Starts something on a listening screen: a title by kind and id (from search), a show by " \
        "name, which plays the profile's next episode, or a camera or web stream by name (\"show the front door in " \
        "the living room\"). A title resumes where the profile left off unless from_start; a stream plays live."
      input_schema(
        properties: {
          screen: { type: "string", description: "The screen's name, e.g. \"living room\"; may be left out when only one is listening." },
          kind: { type: "string", enum: KINDS, description: "With id: what to play." },
          id: { type: "string" },
          show: { type: "string", description: "Instead of kind and id: a show, whose next episode plays." },
          stream: { type: "string", description: "Instead: a camera or web stream by name, e.g. \"front door\" (live_streams lists them)." },
          profile: PROFILE_ARGUMENT,
          from_start: { type: "boolean", description: "Start at the beginning instead of resuming." }
        }
      )
      annotations(title: "Play on a screen", read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: false)

      sig do
        params(server_context: T.untyped, screen: T.untyped, kind: T.untyped, id: T.untyped, show: T.untyped, profile: T.untyped,
          from_start: T.untyped, stream: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response)
      end
      def self.call(server_context:, screen: nil, kind: nil, id: nil, show: nil, profile: nil, from_start: false, stream: nil, **_extra)
        user = context_user(server_context)
        as_profile(server_context, profile) do |viewer|
          playable =
            if stream.to_s.strip.present?
              find_live_stream(stream)
            elsif show.to_s.strip.present?
              found = find_show(show)
              Viewing::NextUp.for(found, viewer)&.episode || raise(NotFound, "#{found.title} has nothing left to watch for #{viewer.name}.")
            elsif kind.present? && id.present?
              find_playable(kind, id)
            else
              raise NotFound, "Say what to play: kind and id (from search), or a show."
            end
          device = Remote::Control.find_device(screen&.to_s)
          Remote::Control.play(device, playable, profile: viewer, user: user, start: from_start ? 0.0 : nil)
          json_response(playing: playable_json(playable), screen: device.display_name, profile: viewer.name,
            note: "The screen picks it up within a few seconds.")
        end
      rescue NotFound, Remote::Control::Error => e
        failure(e.message)
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class NextUp < Base
      tool_name "next_up"
      title "What's next"
      description "With a show: the episode a profile would watch next (the one in progress, else the next unwatched). " \
        "Without: what the profile is in the middle of, most recent first."
      input_schema(
        properties: { show: { type: "string", description: "A show's name or id." }, profile: PROFILE_ARGUMENT }
      )
      annotations(title: "What's next", read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      sig { override.returns(T::Boolean) }
      def self.read_only? = true

      sig { params(server_context: T.untyped, show: T.untyped, profile: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, show: nil, profile: nil, **_extra)
        as_profile(server_context, profile) do |viewer|
          if show.to_s.strip.present?
            found = find_show(show)
            pick = Viewing::NextUp.for(found, viewer)
            next failure("#{found.title} has nothing left to watch for #{viewer.name}.") if pick.nil?

            json_response(profile: viewer.name, show: found.title, next: playable_json(pick.episode).merge(
              resume_at: pick.state&.completed? ? 0 : pick.state&.position_seconds.to_f.round, started_show: pick.started_show
            ))
          else
            states = WatchState.in_progress.where(profile: viewer).order(last_watched_at: :desc).limit(10).includes(:playable).to_a
            allowed = Viewing::Access.permitted(states.filter_map(&:playable)).to_set
            json_response(profile: viewer.name, in_progress: states.select { |state| allowed.include?(state.playable) }.map do |state|
              playable_json(state.playable).merge(position_seconds: state.position_seconds.round, last_watched_at: state.last_watched_at)
            end)
          end
        end
      rescue NotFound => e
        failure(e.message)
      end
    end
  end
end

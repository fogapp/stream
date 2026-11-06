# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class Search < Base
      tool_name "search"
      title "Search the library"
      description "Finds films, shows, episodes and YouTube videos by title, forgiving typos. Returns kinds and ids " \
        "to pass to play_on_screen (a show is played through next_up or play_on_screen's `show`)."
      input_schema(
        properties: { query: { type: "string", description: "What to look for." }, profile: PROFILE_ARGUMENT },
        required: %w[query]
      )
      annotations(title: "Search the library", read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      sig { override.returns(T::Boolean) }
      def self.read_only? = true

      sig { params(query: T.untyped, server_context: T.untyped, profile: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response) }
      def self.call(query:, server_context:, profile: nil, **_extra)
        as_profile(server_context, profile) do
          found = Viewing::Search.call(query.to_s)
          json_response(
            movies: found.fetch(:movies).map { |movie| { kind: "movie", id: movie.id, title: movie.title, year: movie.year } },
            shows: found.fetch(:shows).map { |show| { kind: "show", id: show.id, title: show.title, year: show.year } },
            episodes: found.fetch(:episodes).map { |episode| playable_json(episode) },
            videos: found.fetch(:videos).map { |video| playable_json(video) }
          )
        end
      rescue NotFound => e
        failure(e.message)
      end
    end
  end
end

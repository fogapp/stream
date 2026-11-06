# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    # Shared spine for Stream's MCP tools (hook:app/services/mcp/tools/
    # base.rb): expected failures come back as `failure(...)`, a message the
    # agent can act on, never a raised exception; results are JSON text.
    # Every catalog read happens as a profile, so a kid profile's limits
    # hold here too (Viewing::Access).
    class Base < MCP::Tool
      extend T::Sig

      PROFILE_ARGUMENT = T.let({ type: "string", description: "Whose watch history counts (a profile's name); defaults to the household's usual one." }.freeze,
        T::Hash[Symbol, String])
      KINDS = T.let(%w[movie episode video clip live_stream].freeze, T::Array[String])

      class NotFound < StandardError; end

      # Whether the tool only looks. A read-scoped API token (ApiToken::Scope)
      # is handed only the tools that say so, and refused a call to any
      # other, so a new tool is hidden from read tokens until it opts in.
      sig { returns(T::Boolean) }
      def self.read_only? = false

      sig { params(payload: T.untyped).returns(MCP::Tool::Response) }
      def self.json_response(payload)
        MCP::Tool::Response.new([ { type: "text", text: JSON.pretty_generate(payload) } ])
      end

      sig { params(message: String).returns(MCP::Tool::Response) }
      def self.failure(message)
        MCP::Tool::Response.new([ { type: "text", text: message } ], error: true)
      end

      sig { params(server_context: T.untyped).returns(User) }
      def self.context_user(server_context) = T.cast(server_context[:user], User)

      sig { params(server_context: T.untyped).returns(Household) }
      def self.context_household(server_context) = T.cast(server_context[:household], Household)

      # The profile a name means, or the household's usual one; the block
      # runs watching as it.
      sig do
        type_parameters(:R).params(server_context: T.untyped, name: T.untyped,
          block: T.proc.params(profile: Profile).returns(T.type_parameter(:R))).returns(T.type_parameter(:R))
      end
      def self.as_profile(server_context, name, &block)
        household = context_household(server_context)
        profiles = Profile.unscoped.where(household_id: household.id).order(:position, :created_at).to_a
        wanted = name.to_s.strip.downcase
        profile =
          if wanted.empty?
            Profile.open_default_for(household)
          else
            NameMatch.find(profiles, wanted, loosely: false) { |candidate| [ candidate.name ] } ||
              raise(NotFound, "No profile is called \"#{name}\". Profiles: #{profiles.map(&:name).join(', ')}.")
          end
        previous = Current.profile
        Current.profile = profile
        begin
          yield profile
        ensure
          Current.profile = previous
        end
      end

      # A camera or web stream by name (PROPOSAL §7.8), if the watching
      # profile may see it: exactly, else the one whose name starts so, else
      # contains it.
      sig { params(name: T.untyped).returns(LiveStream) }
      def self.find_live_stream(name)
        streams = Viewing::Access.live_streams(LiveStream.all).order(:sort_title).to_a
        NameMatch.find(streams, name.to_s) { |stream| [ stream.name ] } ||
          raise(NotFound, "No camera or stream is called \"#{name}\". #{streams.any? ? "There's #{streams.map(&:name).to_sentence}." : 'There are none.'}")
      end

      # A title by kind and id, if the watching profile may see it.
      sig { params(kind: T.untyped, id: T.untyped).returns(T.any(Movie, Episode, Video, Clip, LiveStream)) }
      def self.find_playable(kind, id)
        T.cast(Viewing::Playables.find!(kind, id, only: KINDS), T.any(Movie, Episode, Video, Clip, LiveStream))
      rescue ActiveRecord::RecordNotFound
        raise NotFound, "No #{kind} has the id #{id}. Use `search` to find one."
      end

      # A Grid channel among those a profile may see, by number or name.
      sig { params(stations: T::Array[Station], wanted: T.untyped).returns(Station) }
      def self.find_station(stations, wanted)
        text = wanted.to_s.strip.downcase
        stations.find { |station| station.number == text } ||
          stations.find { |station| station.name.downcase == text || station.call_sign.to_s.downcase == text } ||
          stations.find { |station| station.name.downcase.start_with?(text) } ||
          raise(NotFound, "No channel is \"#{wanted}\". Channels: #{stations.map { |station| "#{station.number} #{station.name}" }.join(', ')}.")
      end

      # A show by id, or by name as search would find it.
      sig { params(show: T.untyped).returns(Show) }
      def self.find_show(show)
        text = show.to_s.strip
        found = Viewing::Catalog.watchable_shows.find_by(id: text) if text.match?(/\A\h{8}-/)
        found ||= Viewing::Search.call(text).fetch(:shows).first
        found || raise(NotFound, "No show matches \"#{text}\".")
      end

      sig { params(playable: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
      def self.playable_json(playable)
        heading = PlaybackSessionSerializer.heading(playable)
        { kind: playable.class.name.to_s.underscore, id: playable.id, title: heading[:title], subtitle: heading[:subtitle] }
      end
    end
  end
end

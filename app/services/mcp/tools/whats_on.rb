# typed: strict
# frozen_string_literal: true

module Mcp
  module Tools
    class WhatsOn < Base
      tool_name "whats_on"
      title "What's on the Grid"
      description "The household's Grid channels (made from the library) and what each is airing now and next — " \
        "or at another time. Channels a profile may not see, or hid, are left out."
      input_schema(
        properties: {
          channel: { type: "string", description: "Only this channel: its number or name." },
          at: { type: "string", description: "Another moment, as an ISO 8601 time (e.g. tonight at 8); defaults to now." },
          profile: PROFILE_ARGUMENT
        }
      )
      annotations(title: "What's on the Grid", read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

      sig { override.returns(T::Boolean) }
      def self.read_only? = true

      sig { params(server_context: T.untyped, channel: T.untyped, at: T.untyped, profile: T.untyped, _extra: T.untyped).returns(MCP::Tool::Response) }
      def self.call(server_context:, channel: nil, at: nil, profile: nil, **_extra)
        context_household(server_context)
        moment = at.present? ? Time.zone.parse(at.to_s) : Time.current
        raise NotFound, "\"#{at}\" isn't a time I can read; use ISO 8601." if moment.nil?

        as_profile(server_context, profile) do |viewer|
          hidden = StationHide.where(profile: viewer).select(:station_id)
          stations = Viewing::Access.stations(Station.in_order.where.not(id: hidden)).includes(:live_stream).to_a
          stations = [ find_station(stations, channel) ] if channel.present?
          zone = AppSetting.cached.zone
          upcoming = next_two(stations.map(&:id), moment)
          json_response(stations.map do |station|
            # A channel showing a camera or web stream (PROPOSAL §7.8): the stream, all day.
            stream = station.live_stream
            next { number: station.number, name: station.name, on: { title: stream.name, subtitle: stream.online? ? "Live" : "Offline" }, next: nil } if stream

            airings = upcoming.fetch(station.id, [])
            first = airings.first
            on, following = first && first.starts_at <= moment ? [ first, airings.second ] : [ nil, first ]
            { number: station.number, name: station.name, on: on && program(on, zone), next: following && program(following, zone) }
          end)
        end
      rescue NotFound => e
        failure(e.message)
      end

      # Each channel's next two programs not over by `moment`, for every
      # channel in one query, with what their headings read.
      sig { params(station_ids: T::Array[String], moment: ActiveSupport::TimeWithZone).returns(T::Hash[String, T::Array[Airing]]) }
      def self.next_two(station_ids, moment)
        ranked = Airing.where(station_id: station_ids, filler: false).where("ends_at > ?", moment)
          .select("airings.*, ROW_NUMBER() OVER (PARTITION BY station_id ORDER BY starts_at) AS place")
        airings = Airing.from(ranked, :airings).where("place <= 2").order(:starts_at).includes(:playable).to_a
        playables = airings.map(&:playable)
        ActiveRecord::Associations::Preloader.new(records: playables.grep(Episode), associations: :show).call
        ActiveRecord::Associations::Preloader.new(records: playables.grep(Video), associations: :channel).call
        airings.group_by(&:station_id)
      end
      private_class_method :next_two

      sig { params(airing: Airing, zone: ActiveSupport::TimeZone).returns(T::Hash[Symbol, T.untyped]) }
      def self.program(airing, zone)
        heading = airing.game? ? { title: airing.program_title, subtitle: airing.program_subtitle || "MLB.tv" } : PlaybackSessionSerializer.heading(airing.playable)
        { title: heading[:title], subtitle: heading[:subtitle], starts: airing.starts_at.in_time_zone(zone).strftime("%a %-l:%M%P"),
          ends: airing.ends_at.in_time_zone(zone).strftime("%-l:%M%P") }
      end
      private_class_method :program
    end
  end
end

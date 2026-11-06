# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # The Grid guide (PROPOSAL §7.7): the profile's channels and what's
    # on each between two times — by default from half an hour ago to three
    # hours ahead, at most a day and a bit at once.
    class GuideController < BaseController
      MAX_WINDOW = T.let(26.hours, ActiveSupport::Duration)

      sig { void }
      def show
        now = Time.current
        from = parse_param_time(:from) || (now - 30.minutes)
        to = parse_param_time(:to) || (now + 3.hours)
        return render_errors("The guide's window ends after it starts") if to <= from

        to = [ to, from + MAX_WINDOW ].min
        hidden = StationHide.where(profile: current_profile!).select(:station_id)
        stations = Viewing::Access.stations(Station.in_order.where.not(id: hidden), now: now).to_a
        airings = Airing.where(station_id: stations.map(&:id)).where("starts_at < ? AND ends_at > ?", to, from).order(:starts_at).to_a
        reminded = AiringReminder.where(profile: current_profile!, airing_id: airings.map(&:id)).pluck(:airing_id).to_set
        favorites = StationFavorite.where(profile: current_profile!).pluck(:station_id).to_set
        by_station = StationSerializer.airings_json(airings, reminded: reminded).group_by { |airing| airing[:station_id] }
        streams = LiveStream.where(id: stations.filter_map(&:live_stream_id)).index_by(&:id)
        stations.each do |station|
          stream = streams[station.live_stream_id]
          by_station[station.id] = [ StationSerializer.stream_airing_json(station, stream, from: from, to: to) ] if stream
        end
        render json: {
          now: now.iso8601(3), from: from.iso8601, to: to.iso8601, time_zone: AppSetting.cached.zone.tzinfo.name,
          stations: stations.map do |station|
            StationSerializer.station_json(station, favorite: favorites.include?(station.id)).merge(airings: by_station.fetch(station.id, []))
          end
        }
      end
    end
  end
end

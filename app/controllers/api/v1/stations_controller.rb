# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Grid channels (PROPOSAL §7.7): anyone sees the lineup their profile
    # may, and hides channels they never want; an admin makes and programs
    # them. Saving a channel rebuilds its schedule from the end of what's on.
    class StationsController < BaseController
      finds :station, from: -> { Station.all }
      skip_before_action :set_station, only: %i[index create options preview preset]
      before_action :require_admin!, except: %i[index hide unhide favorite unfavorite]
      # A preview keeps nothing: a read token may ask for one.
      allow_read_scope :preview

      # The lineup in number order; hidden channels only when asked for
      # (hidden=1), flagged.
      sig { void }
      def index
        hidden = StationHide.where(profile: current_profile!).pluck(:station_id).to_set
        favorites = StationFavorite.where(profile: current_profile!).pluck(:station_id).to_set
        stations = Viewing::Access.stations(Station.in_order).to_a
        stations = stations.reject { |station| hidden.include?(station.id) } unless bool_param(:hidden)
        render json: stations.map { |station|
          StationSerializer.station_json(station, hidden: hidden.include?(station.id), favorite: favorites.include?(station.id))
        }
      end

      sig { void }
      def show
        render json: StationSerializer.config_json(station)
      end

      sig { void }
      def create
        created = Station.new
        save(created, status: :created)
      end

      sig { void }
      def update
        save(station, status: :ok)
      end

      sig { void }
      def destroy
        station.destroy!
        head :no_content
      end

      sig { void }
      def hide
        StationHide.insert_all([ { profile_id: current_profile!.id, station_id: station.id, created_at: Time.current } ],
          unique_by: %i[profile_id station_id])
        head :no_content
      end

      sig { void }
      def unhide
        StationHide.where(profile: current_profile!, station: station).delete_all
        head :no_content
      end

      sig { void }
      def favorite
        StationFavorite.insert_all([ { profile_id: current_profile!.id, station_id: station.id, created_at: Time.current } ],
          unique_by: %i[profile_id station_id])
        head :no_content
      end

      sig { void }
      def unfavorite
        StationFavorite.where(profile: current_profile!, station: station).delete_all
        head :no_content
      end

      # The next week as saving these settings would schedule it, and what's
      # worth knowing about it (station_id to preview an existing channel's
      # edit). Nothing is kept.
      sig { void }
      def preview
        target = params[:station_id].present? ? Station.find(params[:station_id].to_s) : Station.new
        assign(target)
        blocks = blocks_param || []
        return if performed?
        return render_errors(target.errors.full_messages) unless target.valid?

        render json: Stations::Preview.run(target, blocks)
      end

      # A ready-made channel to start from (a network's week, kids, a decade…),
      # as a draft for the editor — nothing is saved.
      sig { void }
      def preset
        kind = Stations::Presets::Kind.try_deserialize(params[:kind].to_s)
        return render_errors("That isn't a kind of channel Stream can make") if kind.nil?

        render json: Stations::Presets.build(current_household!.id, kind, params[:value].presence&.to_s)
      end

      # What the channel editor offers to choose from: the library's own
      # genres, networks, studios and keywords (most titles first), its
      # shows and its collections.
      sig { void }
      def options
        render json: {
          genres: tally("genres", Movie, Show), networks: tally("networks", Show), studios: tally("studios", Movie),
          keywords: tally("keywords", Movie, Show).first(300),
          shows: Show.order(:sort_title).pluck(:id, :title, :year).map { |id, title, year| { id: id, title: title, year: year } },
          collections: Collection.order(:sort_title).pluck(:id, :title).map { |id, title| { id: id, title: title } },
          youtube_channels: Channel.order(:title).pluck(:id, :title).map { |id, title| { id: id, title: title } },
          live_streams: LiveStream.order(:sort_title).pluck(:id, :name, :mlb_team_id).map { |id, name, team| { id: id, name: name, mlb_team: !team.nil? } },
          mlb_teams: mlb_teams,
          decades: decades,
          time_zone: AppSetting.cached.zone.tzinfo.name
        }
      end

      private

      sig { params(target: Station, status: Symbol).void }
      def save(target, status:)
        assign(target)
        blocks = blocks_param
        return if performed?

        Station.transaction do
          target.save!
          target.replace_blocks!(blocks) if blocks
        end
        Stations::Scheduler.rebuild!(target.reload)
        render json: StationSerializer.config_json(target.reload), status: status
      end

      sig { params(target: Station).void }
      def assign(target)
        target.assign_attributes(params.permit(:number, :name, :call_sign, :snap_minutes, :no_repeat_days, :filler, :breaks).to_h)
        if params.key?(:live_stream_id)
          # Only a stream this household has, and that the lineup may show.
          target.live_stream = params[:live_stream_id].present? ? LiveStream.find(params[:live_stream_id].to_s) : nil
        end
        target.mlb_team_ids = Array(params[:mlb_team_ids]).map { |id| id.to_s.to_i }.first(30) if params.key?(:mlb_team_ids)
        target.filler_channel_ids = Array(params[:filler_channel_ids]).map(&:to_s).grep(Stations::Rules::UUID).first(50) if params.key?(:filler_channel_ids)
        target.call_sign = target.call_sign.presence
      end

      # The channel's programming, top to bottom; nil when not sent. One
      # base block at most.
      sig { returns(T.nilable(T::Array[T::Hash[Symbol, T.untyped]])) }
      def blocks_param
        return nil unless params.key?(:blocks)

        raw = Array(params[:blocks]).map { |block| block.respond_to?(:to_unsafe_h) ? block.to_unsafe_h.to_h : {} }
        if raw.count { |block| block["layer"].to_s == StationBlock::Layer::Base.serialize } > 1
          render_errors("A channel has one mix for when nothing else is on")
          return nil
        end
        int = ->(value) { value.to_s.match?(/\A\d+\z/) ? value.to_i : nil }
        raw.first(50).map do |block|
          {
            layer: block["layer"].to_s, name: block["name"].to_s.strip.presence, days: int.call(block["days"]) || StationBlock::EVERY_DAY,
            start_minute: int.call(block["start_minute"]), end_minute: int.call(block["end_minute"]),
            starts_on: block["starts_on"].presence, ends_on: block["ends_on"].presence,
            source: Stations::Rules.normalize(block["source"]), ordering: block["ordering"].presence || "shuffle",
            marathon_length: int.call(block["marathon_length"]) || 3,
            loops: block.key?("loops") ? ActiveModel::Type::Boolean.new.cast(block["loops"]) || false : true
          }
        end
      end

      # The clubs whose games a channel can carry, once the household has
      # an MLB.tv account; none when MLB's list can't be read.
      sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
      def mlb_teams
        return [] unless MlbSetting.exists?

        Mlb::Schedule.new.teams.map { |team| { id: team.fetch("id"), name: team.fetch("name") } }
      rescue Mlb::Schedule::Error
        []
      end

      # The decades the library's shows and films come from, most first.
      sig { returns(T::Array[T::Hash[Symbol, Integer]]) }
      def decades
        counts = Hash.new(0)
        [ Show, Movie ].each do |model|
          model.where.not(year: nil).group(Arel.sql("(year / 10) * 10")).count.each { |decade, count| counts[decade.to_i] += count }
        end
        counts.sort_by { |decade, _| -decade }.map { |decade, count| { value: decade, count: count } }
      end

      # A string-array column's values across titles, most common first.
      sig { params(column: String, models: T.class_of(ApplicationRecord)).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
      def tally(column, *models)
        counts = Hash.new(0)
        models.each do |model|
          model.where.not(column => []).group(Arel.sql("unnest(#{column})")).count.each { |value, count| counts[value] += count }
        end
        counts.sort_by { |value, count| [ -count, value.to_s ] }.map { |value, count| { value: value, count: count } }
      end
    end
  end
end

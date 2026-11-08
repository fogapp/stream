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

      # What the channel editor offers to choose from (Stations::EditorOptions).
      sig { void }
      def options
        render json: Stations::EditorOptions.call
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

      # The channel's programming (Stations::BlockParams); nil when not
      # sent, or when it can't be taken (the errors rendered).
      sig { returns(T.nilable(T::Array[T::Hash[Symbol, T.untyped]])) }
      def blocks_param
        return nil unless params.key?(:blocks)

        Stations::BlockParams.normalize(params[:blocks])
      rescue Stations::BlockParams::Invalid => e
        render_errors(e.message)
        nil
      end
    end
  end
end

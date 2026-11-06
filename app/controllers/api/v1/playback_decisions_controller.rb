# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # The admin Playback decisions page (PROPOSAL §7.6): why each press of
    # Play went the way it did, at a glance. Admins only.
    class PlaybackDecisionsController < BaseController
      before_action :require_admin!

      # Every press of Play, a page at a time: searchable by title, filtered
      # by method, outcome, profile, device and when, sorted by any column.
      sig { void }
      def index
        scope = Playback::SessionQuery.new(session_filters).scope.includes(:profile, :device, :media_file, playable: :show)
        render json: paged(scope) { |sessions| sessions.map { |session| PlaybackDecisionSerializer.row_json(session) } }
      end

      # One session in full: its decision and what its player reported.
      sig { void }
      def show
        session = Playback::SessionQuery.new(Playback::SessionQuery::Filters.new).scope
          .includes(:profile, :device, :media_file, playable: :show).find(params[:id])
        render json: PlaybackDecisionSerializer.detail_json(session)
      end

      # Is playback healthy, and is there something to do about it?
      sig { void }
      def health
        render json: PlaybackHealthSerializer.json(Playback::Health.checks)
      end

      # Who and what has played, for the Sessions table's filters.
      sig { void }
      def facets
        sessions = PlaybackSession.watched
        render json: {
          profiles: Profile.where(id: sessions.select(:profile_id)).order(:name).map { |profile| { id: profile.id, name: profile.name } },
          devices: Device.where(id: sessions.select(:device_id)).order(:name).map { |device| { id: device.id, name: device.name } }
        }
      end

      sig { void }
      def summary
        render json: Playback::Report.summary(since: 7.days.ago).merge(
          devices: Device.recent.order(last_seen_at: :desc).map { |device| { id: device.id, name: device.name, last_seen_at: device.last_seen_at } },
          cap: Playback::Placement.capacity, encoder: Playback::Encoders.kind,
          remote_transcoders: TranscodeNode.online.count,
          converting_now: PlaybackSession.converting_now.count
        )
      end

      # The files some recent device would convert, as a table: how often
      # each actually was this month, and where it stands on being optimized.
      sig { void }
      def transcode_report
        rows, facets = Playback::ConversionQuery.new(current_household!, conversion_filters).call
        render json: paged_rows(rows).merge(facets: facets)
      end

      private

      sig { returns(Playback::ConversionQuery::Filters) }
      def conversion_filters
        statuses = Array(params[:statuses]).map(&:to_s)
          .select { |value| value == Playback::ConversionQuery::NONE || OptimizedVersion::State.try_deserialize(value) }
        Playback::ConversionQuery::Filters.new(
          query: params[:q].presence&.to_s, statuses: statuses, device: params[:device].presence&.to_s,
          library_id: params[:library_id].presence&.to_s, all_devices: bool_param(:all_devices),
          sort: params[:sort].presence&.to_s || "conversions", direction: params[:direction].presence&.to_s || "desc"
        )
      end

      sig { returns(Playback::SessionQuery::Filters) }
      def session_filters
        Playback::SessionQuery::Filters.new(
          query: params[:q].presence&.to_s,
          play_methods: Array(params[:methods]).filter_map { |value| PlaybackSession::Method.try_deserialize(value.to_s) },
          outcomes: Array(params[:outcomes]).filter_map { |value| PlaybackSession::Outcome.try_deserialize(value.to_s) },
          profile_id: params[:profile_id].presence&.to_s, device_id: params[:device_id].presence&.to_s,
          from: parse_param_time(:from), to: parse_param_time(:to),
          sort: params[:sort].to_s, direction: params[:direction].to_s
        )
      end
    end
  end
end

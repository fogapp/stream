# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Optimized versions (PROPOSAL §5.5): what's made, what's waiting for
    # quiet hours, and asking for one. Admins only.
    class OptimizedVersionsController < BaseController
      before_action :require_admin!
      finds :optimized_version, from: -> { OptimizedVersion.all }
      skip_before_action :set_optimized_version, only: %i[index create status bulk scan]

      # The Queue and Optimized tables, a page at a time: filtered by state,
      # origin, reason, interruptions, search and how long since the file
      # was played; in the transcoder's order or by any column.
      sig { void }
      def index
        scope = Playback::OptimizedQuery.new(filters).scope.includes(media_file: { editions: { playable: :show } })
        fit = Playback::OptimizerStatus.queue_fit
        render json: paged(scope) { |versions| versions.map { |version| OptimizedVersionSerializer.table_json(version, fit[version.id]) } }
      end

      # One action on many files at once — or one: { action:, media_file_ids:, now: }.
      sig { void }
      def bulk
        action = Playback::OptimizeActions::Action.try_deserialize(params[:bulk_action].to_s)
        return render_errors("Unknown action") unless action

        ids = Array(params.require(:media_file_ids)).map(&:to_s)
        return render_not_found unless MediaFile.exists?(id: ids)

        result = Playback::OptimizeActions.new(action: action, media_file_ids: ids, now: bool_param(:now), household: current_household!).call
        if result.changed.positive?
          Activity.record(source: "playback", event: "optimize.#{action.serialize}",
            summary: "#{current_user!.name} #{Playback::OptimizeActions.summary(action, result.changed, now: bool_param(:now))}")
        end
        render json: { changed: result.changed, unchanged: result.unchanged }
      end

      # Look for files to optimize now rather than at ten to the hour.
      sig { void }
      def scan
        return render_errors("Optimizing automatically is off (Settings › General)") unless AppSetting.cached.optimize_automatically

        QueueOptimizationsJob.perform_later
        head :accepted
      end

      # What the optimizer is doing and, when it isn't, why not.
      sig { void }
      def status
        render json: Playback::OptimizerStatus.current
      end

      # Optimize a file: queued ahead of anything automatic, and with now=true
      # encoded straight away rather than in quiet hours.
      sig { void }
      def create
        file = MediaFile.find(params.require(:media_file_id))
        return render_errors("This file can't be read yet") unless file.state_enum == MediaFile::State::Probed

        version = OptimizedVersion.find_or_initialize_by(media_file: file)
        version.household_id = current_household!.id
        version.save! if version.new_record?
        version.requeue!(origin: OptimizedVersion::Origin::Manual, run_now: bool_param(:now)) unless version.state_enum == OptimizedVersion::State::Encoding
        Activity.record(source: "playback", event: "optimize.requested", subject: file,
          summary: "#{current_user!.name} asked for an optimized version of #{file.filename}")
        render json: OptimizedVersionSerializer.json(version), status: :created
      end

      sig { void }
      def retry
        optimized_version.requeue!(run_now: bool_param(:now))
        render json: OptimizedVersionSerializer.json(optimized_version)
      end

      # Deleting stops an encode in progress too: the transcoder notices
      # its row is gone on its next tick.
      sig { void }
      def destroy
        optimized_version.destroy!
        head :no_content
      end

      private

      sig { returns(Playback::OptimizedQuery::Filters) }
      def filters
        Playback::OptimizedQuery::Filters.new(
          query: params[:q].presence&.to_s,
          states: Array(params[:states]).filter_map { |value| OptimizedVersion::State.try_deserialize(value.to_s) },
          origin: OptimizedVersion::Origin.try_deserialize(params[:origin].to_s),
          reasons: Array(params[:reasons]).filter_map { |value| OptimizedVersion::Reason.try_deserialize(value.to_s) },
          interrupted: bool_param(:interrupted),
          unplayed_days: params[:unplayed_days].presence && params[:unplayed_days].to_i.clamp(1, 3650),
          sort: params[:sort].to_s, direction: params[:direction].to_s
        )
      end
    end
  end
end

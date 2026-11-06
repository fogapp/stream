# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # What Stream knows about each file (PROPOSAL §8.2): the list behind the
    # library's file view and Needs attention, and the per-file analysis page.
    class MediaFilesController < BaseController
      finds :media_file, from: -> { MediaFile.includes(:library, :media_streams, :analysis_runs, editions: :playable) }
      skip_before_action :set_media_file, only: :index
      before_action :require_admin!, only: %i[rerun set_marker clear_marker]
      # Files and their faults are the running, not the watching.
      before_action :require_grown_up!, only: %i[index show]

      sig { void }
      def index
        scope = MediaFile.includes(:library, editions: :playable).order(:path)
        scope = scope.where(library_id: params[:library_id].to_s) if params[:library_id].present?
        # Exact lookups (Hook's delivery confirmation): by content, by place.
        fingerprints = params[:fingerprint].to_s.split(",").map(&:strip).reject(&:empty?)
        scope = scope.where(fingerprint: fingerprints) if fingerprints.any?
        scope = scope.where(path: params[:path].to_s) if params[:path].present?
        state = MediaFile::State.try_deserialize(params[:state].to_s)
        scope = scope.where(state: state.serialize) if state
        query = params[:q].to_s.strip
        scope = scope.where("path ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(query)}%") if query.present?
        render json: MediaFileSerializer.list_json(paginate(scope).to_a)
      end

      sig { void }
      def show
        render json: MediaFileSerializer.detail_json(media_file)
      end

      # A person's correction to a marker (PROPOSAL §8.2): it outranks chapters
      # and audio matching, and no later detection overwrites it.
      sig { void }
      def set_marker
        kind = Marker::Kind.try_deserialize(params.require(:kind).to_s)
        start = T.let(Float(params.require(:start).to_s, exception: false), T.nilable(Float))
        finish = T.let(Float(params.require(:end).to_s, exception: false), T.nilable(Float))
        return render_errors("Unknown marker kind") if kind.nil?
        return render_errors("Start must come before end") if start.nil? || finish.nil? || start.negative? || finish <= start

        Marker.offer(media_file, kind, start: start, finish: finish, source: Marker::Source::Manual)
        render json: MediaFileSerializer.detail_json(media_file.reload)
      end

      sig { void }
      def clear_marker
        media_file.markers.where(kind: params.require(:kind).to_s).delete_all
        render json: MediaFileSerializer.detail_json(media_file.reload)
      end

      # Runs one analysis step again from the file page's checklist.
      sig { void }
      def rerun
        step = AnalysisRun::Step.try_deserialize(params.require(:step).to_s)
        return render_errors("Unknown step") if step.nil?

        Analysis::Rerun.call(media_file, step)
        head :accepted
      end
    end
  end
end

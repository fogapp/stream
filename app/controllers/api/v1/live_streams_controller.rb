# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Cameras and web streams (PROPOSAL §7.8). Anyone sees the ones their
    # profile may; only an admin adds them, and an address saves only once a
    # probe has read a picture from it. The address is write-only.
    class LiveStreamsController < BaseController
      finds :live_stream, from: -> { Viewing::Access.live_streams(LiveStream.all) }
      skip_before_action :set_live_stream, only: %i[index create test]
      before_action :require_admin!, except: %i[index show]

      sig { void }
      def index
        scope = Viewing::Access.live_streams(LiveStream.added).includes(:media_streams).order(:sort_title)
        scope = scope.where(library_id: params[:library_id].to_s) if params[:library_id].present?
        render json: scope.map { |stream| LiveStreamSerializer.json(stream, admin: admin?) }
      end

      sig { void }
      def show
        render json: LiveStreamSerializer.json(live_stream, admin: admin?)
      end

      sig { void }
      def create
        stream = LiveStream.new(stream_params)
        return render_errors(stream.errors.full_messages) unless stream.valid?

        probed = LiveStreams::Prober.probe(stream)
        stream.save!
        LiveStreams::Prober.call(stream, probed: probed)
        CaptureLiveStillJob.perform_later(stream.id)
        render json: LiveStreamSerializer.json(stream.reload, admin: true), status: :created
      rescue LiveStreams::Prober::Failure => e
        render_errors(e.message)
      end

      # A new address, or a change to how it's read, is probed before it's
      # kept; a name or a rating isn't.
      sig { void }
      def update
        changes = stream_params
        changes.delete(:url) if changes[:url].blank?
        live_stream.assign_attributes(changes)
        return render_errors(live_stream.errors.full_messages) unless live_stream.valid?

        reread = live_stream.will_save_change_to_url? || live_stream.will_save_change_to_trust_certificate? ||
          live_stream.will_save_change_to_feed?
        probed = reread ? LiveStreams::Prober.probe(live_stream) : nil
        live_stream.save!
        LiveStreams::Prober.call(live_stream, probed: probed) if probed
        CaptureLiveStillJob.perform_later(live_stream.id) if probed
        render json: LiveStreamSerializer.json(live_stream.reload, admin: true)
      rescue LiveStreams::Prober::Failure => e
        render_errors(e.message)
      end

      sig { void }
      def destroy
        live_stream.destroy!
        head :no_content
      end

      # Settings' Test button: an address as typed (or the saved one, for an
      # existing stream), probed and forgotten.
      sig { void }
      def test
        attributes = stream_params
        saved = params[:id].present? ? LiveStream.find(params[:id].to_s) : nil
        stream = saved ? saved.dup.tap { |copy| copy.assign_attributes(attributes.reject { |key, value| key.to_s == "url" && value.blank? }) } :
                         LiveStream.new(attributes).tap { |copy| copy.household = current_household! }
        return render json: { ok: false, message: "Enter the stream's address first." } if stream.url.blank?

        result = LiveStreams::Prober.probe(stream)
        render json: { ok: true, message: "Found #{describe(result)}", tracks: LiveStreamSerializer.tracks_json(result.streams) }
      rescue LiveStreams::Prober::Failure => e
        render json: { ok: false, message: e.message }
      end

      # Read the address again: after a camera's settings changed, or to see
      # whether an offline one is back.
      sig { void }
      def probe
        LiveStreams::Prober.call(live_stream)
        CaptureLiveStillJob.perform_later(live_stream.id)
        render json: LiveStreamSerializer.json(live_stream.reload, admin: true)
      rescue LiveStreams::Prober::Failure => e
        render_errors(e.message, status: :bad_gateway)
      end

      private

      sig { returns(T::Boolean) }
      def admin? = current_user!.admin?

      sig { returns(ActionController::Parameters) }
      def stream_params
        params.require(:live_stream).permit(:name, :library_id, :kind, :feed, :url, :trust_certificate, :keep_connected, :content_rating, :description)
      end

      sig { params(result: LiveStreams::Prober::Result).returns(String) }
      def describe(result)
        video = result.streams.find { |row| row[:kind] == MediaStream::Kind::Video.serialize } || {}
        audio = result.streams.count { |row| row[:kind] == MediaStream::Kind::Audio.serialize }
        picture = [ video[:codec].to_s.upcase.sub("H264", "H.264"), video[:height] ? "#{video[:height]}p" : nil,
                    video[:frame_rate] ? "#{video[:frame_rate].round} fps" : nil ].compact.join(" ")
        "#{picture}#{audio.positive? ? " with #{audio} audio track#{'s' if audio > 1}" : ', no sound'}"
      end
    end
  end
end

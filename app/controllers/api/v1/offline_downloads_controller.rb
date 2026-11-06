# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Saving a title into this browser to watch offline (PROPOSAL §11
    # Phase 6). Only a file this browser plays as-is can be downloaded: the
    # original, or its optimized version. A download that would need
    # converting says so instead.
    class OfflineDownloadsController < BaseController
      finds :offline_download, from: -> { OfflineDownload.all }
      skip_before_action :set_offline_download, only: :create
      before_action :require_own_download, except: :create

      sig { void }
      def create
        playable = find_playable

        caps = Playback::Capabilities.from_json(params[:capabilities]&.to_unsafe_h)
        files = playable.playable_files.includes(:media_streams, :optimized_version).to_a
        choice = files.filter_map do |file|
          decision = Playback::Decision.new(file, caps, max_height: 2160)
          [ file, decision ] if [ PlaybackSession::Method::Direct, PlaybackSession::Method::Optimized ].include?(decision.method)
        end.max_by { |file, decision| [ decision.method == PlaybackSession::Method::Direct ? 1 : 0, file.size ] }
        return render_errors(cannot_download_message(files, caps), status: :conflict) if choice.nil?

        file, decision = choice
        version = decision.optimized
        download = OfflineDownload.create!(profile: current_profile!, playable: playable, media_file: file, optimized_version: version,
          size: version ? version.size.to_i : file.size, device_name: Device.name_from(request.user_agent.to_s),
          expires_at: OfflineDownload::LIFETIME.from_now)
        render json: OfflineDownloadSerializer.json(download, token: Playback::DownloadToken.issue(download)), status: :created
      end

      # Where the viewer got to while offline, sent once they're back.
      sig { void }
      def progress
        position = T.let(Float(params[:position].to_s, exception: false), T.nilable(Float))
        return render_errors("A position is needed") if position.nil?

        watched_at = parse_param_time(:watched_at)&.in_time_zone || Time.current
        state = Playback::Progress.report_offline(offline_download, position: position, watched_at: [ watched_at, Time.current ].min)
        offline_download.update!(last_synced_at: Time.current)
        render json: { position_seconds: state.position_seconds, completed: state.completed? }
      end

      # Removed from the browser: the link stops working too.
      sig { void }
      def destroy
        offline_download.destroy!
        head :no_content
      end

      private

      # Another profile's download is as good as missing.
      sig { void }
      def require_own_download
        raise ActiveRecord::RecordNotFound unless offline_download.profile_id == current_profile!.id
      end

      sig { returns(T.any(Movie, Episode, Video, Clip)) }
      def find_playable
        T.cast(Viewing::Playables.find!(params.require(:playable_type), params.require(:playable_id), only: %w[movie episode video clip]),
          T.any(Movie, Episode, Video, Clip))
      end

      sig { params(files: T::Array[MediaFile], caps: Playback::Capabilities).returns(String) }
      def cannot_download_message(files, caps)
        return "There's no readable file for this yet" if files.empty?

        reason = Playback::Decision.new(T.must(files.first), caps, max_height: 2160).summary
        "This browser would need it converted (#{reason.sub(/ — .*/, '')}), so it can't be saved as it is. " \
          "An optimized version can be — an admin can make one from its file page."
      end
    end
  end
end

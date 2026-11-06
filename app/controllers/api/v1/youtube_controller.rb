# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # Settings › YouTube and Add channel (PROPOSAL §5.4): where downloads go,
    # the state of yt-dlp, and turning a pasted link into what Stream will
    # fetch. Admins only: this is the one place Stream acquires media.
    class YoutubeController < BaseController
      before_action :require_admin!
      # Resolving a link looks and keeps nothing: a read token may ask.
      allow_read_scope :resolve

      sig { void }
      def show
        libraries = Library.where(kind: Library::Kind::Channels.serialize).order(:name).to_a
        tracked = Channel.where(tracked: true).order(:sort_title).to_a
        counts = YoutubeDownload.group(:state).count
        render json: {
          yt_dlp_version: Youtube::YtDlp.cached_version,
          libraries: libraries.map do |library|
            { id: library.id, name: library.name, roots: library.roots, download_root: library.download_root, sponsorblock: library.sponsorblock }
          end,
          tracked: tracked.map do |channel|
            { id: channel.id, title: channel.title, last_polled_at: channel.last_polled_at, last_poll_error: channel.last_poll_error }
          end,
          downloads: YoutubeDownload::State.values.to_h { |state| [ state.serialize, counts.fetch(state.serialize, 0) ] },
          end_screen: AppSetting.current.youtube_end_screen
        }
      end

      # { library_id, download_root } — or no library_id to stop downloading.
      sig { void }
      def update
        library_id = params[:library_id].presence
        root = params[:download_root].to_s.chomp("/")
        if library_id
          library = Library.find(library_id)
          return render_errors("Downloads go into a channels library") unless library.kind_enum == Library::Kind::Channels
          return render_errors("Pick one of the library's folders") unless library.roots.include?(root)

          report = StorageLocation.inspect_path(root, writable: true)
          return render_errors(report.message) unless report.ok
        end

        Library.transaction do
          Library.where(kind: Library::Kind::Channels.serialize).where.not(download_root: nil).update_all(download_root: nil) # rubocop:disable Rails/SkipsModelValidations
          Library.find(library_id).update!(download_root: root) if library_id
        end
        show
      end

      # { url } → what it is: a channel, a video or a playlist, and whose.
      sig { void }
      def resolve
        parsed = Youtube::Urls.parse(params.require(:url).to_s)
        render json: YoutubeSerializer.preview(Youtube::Resolver.resolve(parsed))
      rescue Youtube::Urls::Invalid, Youtube::YtDlp::Error => e
        render_errors(e.message)
      end

      # { url, rules } → a tracked channel, or downloads of a video or playlist.
      sig { void }
      def track
        parsed = Youtube::Urls.parse(params.require(:url).to_s)
        preview = Youtube::Resolver.resolve(parsed)
        tracker = Youtube::Tracker.new(current_household!)
        if parsed.kind == Youtube::Urls::Kind::Channel
          channel = tracker.track(preview, rules)
          render json: { channel_id: channel.id, queued: 0 }, status: :created
        else
          rows = tracker.download(preview)
          return render_errors("That video is already in Stream") if rows.empty? && parsed.kind == Youtube::Urls::Kind::Video

          render json: { channel_id: rows.first&.channel_id, queued: rows.size }, status: :created
        end
      rescue Youtube::Urls::Invalid, Youtube::YtDlp::Error, Youtube::Tracker::NoDownloadFolder => e
        render_errors(e.message)
      end

      # { library_id, enabled }: SponsorBlock for a channels library's videos.
      sig { void }
      def sponsorblock
        library = Library.where(kind: Library::Kind::Channels.serialize).find(params.require(:library_id))
        library.update!(sponsorblock: bool_param(:enabled))
        RefreshSponsorSegmentsJob.perform_later if library.sponsorblock
        show
      end

      # { enabled }: whether a finished video offers more to watch over its
      # last frame, for every profile.
      sig { void }
      def end_screen
        AppSetting.current.update!(youtube_end_screen: bool_param(:enabled))
        show
      end

      sig { void }
      def update_tool
        UpdateYtDlpJob.perform_later
        head :accepted
      end

      private

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def rules
        raw = params.fetch(:rules, {}).permit(:backfill, :backfill_count, :backfill_since, :keep_last, :skip_shorts, :skip_live,
          :title_filter, :max_height, :poll_every_hours).to_h.symbolize_keys
        raw[:keep_last] = nil if raw.key?(:keep_last) && raw[:keep_last].blank?
        raw
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # One tracked channel's rules, polls and downloads (PROPOSAL §5.4).
    class ChannelTrackingController < BaseController
      before_action :require_admin!
      finds :channel, from: -> { Channel.all }, param: :channel_id

      sig { void }
      def show
        render json: YoutubeSerializer.tracking(channel).merge(
          recent: channel.youtube_downloads.order(updated_at: :desc).limit(50).map { |row| YoutubeSerializer.download(row) }
        )
      end

      # Rules, or { tracked: false } to stop checking (what's downloaded stays).
      sig { void }
      def update
        changes = params.permit(:tracked, :backfill, :backfill_count, :backfill_since, :keep_last, :skip_shorts, :skip_live,
          :title_filter, :max_height, :poll_every_hours).to_h
        changes["keep_last"] = nil if changes.key?("keep_last") && changes["keep_last"].blank?
        return render_errors(channel.errors.full_messages) unless channel.update(changes)

        Youtube::Retention.new(channel).call if changes.key?("keep_last")
        show
      end

      # { url } of the channel on YouTube: a channel made from a folder learns
      # which one it is — its name, handle, pictures and description — and
      # its videos are looked up there. Nothing is tracked or downloaded.
      sig { void }
      def link
        return render_errors("#{channel.title} is already linked to YouTube") if channel.youtube_id.present?

        parsed = Youtube::Urls.parse(params.require(:url).to_s)
        return render_errors("Paste the channel's link, like youtube.com/@name") unless parsed.kind == Youtube::Urls::Kind::Channel

        info = Youtube::Resolver.resolve(parsed).channel
        return render_errors("YouTube didn't say which channel that is") if info.nil?

        taken = Channel.where(library_id: channel.library_id, youtube_id: info.youtube_id).where.not(id: channel.id).first
        return render_errors("#{taken.title} is already that channel", status: :conflict) if taken

        Youtube::ChannelLink.apply(channel, info)
        IdentifyChannelVideosJob.perform_later(channel.id)
        show
      rescue Youtube::Urls::Invalid, Youtube::YtDlp::Error => e
        render_errors(e.message)
      end

      sig { void }
      def poll
        return render_errors("This channel isn't tracked") unless channel.tracked

        PollChannelJob.perform_later(channel.id)
        head :accepted
      end

      # Try a failed download again, or fetch a finished one again over the
      # file it left (it came down wrong). One the keep-last rule removed
      # comes back kept, or the rule would only remove it again.
      sig { void }
      def retry
        row = channel.youtube_downloads.find(params.require(:download_id))
        return render_errors("It's already on its way") unless row.can_fetch_again?

        row.fetch_again!(kept: row.kept || row.state_enum == YoutubeDownload::State::Removed)
        head :accepted
      end

      # { kept }: keep a download whatever the keep-last rule says, or hand
      # it back to the rule (which may then remove it).
      sig { void }
      def keep
        row = channel.youtube_downloads.find(params.require(:download_id))
        return render_errors("Only a finished download can be kept") unless row.state_enum == YoutubeDownload::State::Done

        row.update!(kept: bool_param(:kept))
        Youtube::Retention.new(channel).call unless row.kept
        show
      end
    end
  end
end

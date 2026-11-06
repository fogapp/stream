# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # A channels library's feed, and a video's watch page (PROPOSAL §5.4):
    # description, chapters, more from the same channel, related videos, and
    # what the player offers when it's over.
    class VideosController < BaseController
      finds :video, from: -> { Viewing::Access.videos(Video.all) }
      skip_before_action :set_video, only: %i[index watched]
      before_action :require_admin!, only: %i[identify not_on_youtube]

      MORE = 12

      # Newest first: a library's videos, or one channel's.
      sig { void }
      def index
        scope = feed
        scope = scope.where.not(id: finished.select(:playable_id)) if bool_param(:unwatched)
        videos = paginate(scope.order(Arel.sql("upload_date DESC NULLS LAST, created_at DESC, id")), default_per: 60).includes(:channel).to_a
        render json: Channels::Catalog.cards(current_profile!, videos)
      end

      # Marks every video of a library's feed (or one channel's) watched — or,
      # with watched=false, unwatched — for this profile; only the ones that change.
      sig { void }
      def watched
        return render_errors("Say which library.") if params[:library_id].blank?

        flag = bool_param(:watched, default: true)
        scope = flag ? feed.where.not(id: finished.select(:playable_id)) : feed.where(id: finished.select(:playable_id))
        scope.find_each { |video| Playback::Progress.mark(current_profile!, video, watched: flag) }
        head :no_content
      end

      sig { void }
      def show
        file = video.best_file
        state = WatchState.find_by(profile: current_profile!, playable: video)
        more = Channels::Catalog.more_from_channel(current_profile!, video, limit: MORE)
        # Beside More from the channel, and not what it already shows.
        related = Recommendations::Similar.videos(video, exclude: more.map(&:id))
        card = Channels::Catalog.cards(current_profile!, [ video ]).first || {}
        render json: card.merge(
          description: video.description, tags: video.tags, url: video.url, youtube_id: video.youtube_id,
          source: video.source_enum, identity: video.identity_enum,
          youtube_candidates: Video::UNIDENTIFIED.include?(video.identity_enum) ? video.youtube_candidates : [],
          chapters: Channels::Catalog.chapters(video, file),
          playable: !file.nil?, resume_at: state&.resume_seconds,
          more_from_channel: Channels::Catalog.cards(current_profile!, more),
          related: Channels::Catalog.cards(current_profile!, related),
          end_screen: Channels::EndScreen.json(current_profile!, video, more: more, related: related),
          retention: retention
        )
      end

      # "This is the one" (a candidate's id) or a pasted link: the video is
      # that YouTube video, and its details are fetched.
      sig { void }
      def identify
        youtube_id = params[:youtube_id].presence&.to_s || Youtube::Urls.parse(params.require(:url).to_s).then do |parsed|
          parsed.kind == Youtube::Urls::Kind::Video ? parsed.id : raise(Youtube::Urls::Invalid, "Paste the link to one video")
        end
        return render_errors("That isn't a YouTube video id") unless youtube_id.match?(Youtube::Urls::VIDEO_ID)

        taken = Video.unscoped.where(library_id: video.library_id, youtube_id: youtube_id).where.not(id: video.id).first
        return render_errors("#{taken.title} is already that video", status: :conflict) if taken

        video.update!(youtube_id: youtube_id, identity: Video::Identity::Identified.serialize, youtube_candidates: [],
          url: Youtube::Urls.video_url(youtube_id))
        HydrateVideoJob.perform_later(video.id)
        head :accepted
      rescue Youtube::Urls::Invalid => e
        render_errors(e.message)
      end

      # None of them: it isn't on YouTube (or can't be found), so stop asking.
      sig { void }
      def not_on_youtube
        video.update!(identity: Video::Identity::NotOnYoutube.serialize, youtube_candidates: [])
        head :no_content
      end

      private

      sig { returns(T.untyped) }
      def feed
        scope = Video.all
        scope = scope.where(library_id: params[:library_id].to_s) if params[:library_id].present?
        scope = scope.where(channel_id: params[:channel_id].to_s) if params[:channel_id].present?
        Channels::Catalog.watchable_videos(scope)
      end

      sig { returns(T.untyped) }
      def finished = WatchState.finished(current_profile!, "Video")

      # For an admin, when Stream downloaded this video: the download, to
      # fetch again or to mark to keep — which matters when the channel's
      # keep-last rule would one day remove it (keep_last isn't null).
      sig { returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def retention
        return unless current_user!.admin? && !current_profile!.kid?

        row = YoutubeDownload.find_by(channel_id: video.channel_id, youtube_id: video.youtube_id, state: YoutubeDownload::State::Done.serialize)
        return if row.nil?

        { download_id: row.id, kept: row.kept, keep_last: video.channel.keep_last }
      end
    end
  end
end

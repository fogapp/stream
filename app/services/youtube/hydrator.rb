# typed: strict
# frozen_string_literal: true

module Youtube
  # Gives an identified video what an info.json would have (PROPOSAL §5.4):
  # its real title, description, upload date, tags, chapters and thumbnail,
  # asked of YouTube by id. Nothing is written beside the file — the details
  # live on the video row (media invariant 1), and a rematch keeps them
  # unless an info.json turns up beside the file.
  #
  # The first video of a folder-made channel to be identified also tells
  # the channel which YouTube channel it is, and the rest of its videos are
  # then looked up too.
  class Hydrator
    extend T::Sig

    sig { params(video: Video).void }
    def initialize(video)
      @video = video
    end

    sig { void }
    def call
      youtube_id = @video.youtube_id
      return if youtube_id.nil?

      file = @video.media_files.max_by { |each| each.size.to_i }
      return apply(youtube_id) if file.nil?

      AnalysisRun.track(file, AnalysisRun::Step::YoutubeDetails, tool_version: "yt-dlp") { apply(youtube_id) }
    end

    private

    sig { params(youtube_id: String).void }
    def apply(youtube_id)
      data = YtDlp.video(Urls.video_url(youtube_id))
      raise YtDlp::Error, "YouTube answered for #{data['id']}, not #{youtube_id}" if data["id"] != youtube_id

      details = Channels::Sidecars.from_info(data, source: Video::Source::Youtube)
      @video.assign_unlocked(
        title: details.title || @video.title, description: details.description,
        upload_date: details.upload_date || @video.upload_date, tags: details.tags, chapters: details.chapters,
        url: details.url || Urls.video_url(youtube_id)
      )
      @video.source = Video::Source::Youtube.serialize
      @video.thumbnail_url = thumbnail(data)
      @video.save!

      claim_channel(details)
      SyncArtworkJob.perform_later("Video", @video.id)
      library = @video.library
      FetchSponsorSegmentsJob.perform_later(@video.id) if library&.sponsorblock && @video.sponsorblock_checked_at.nil?
    end

    # Only an i.ytimg.com picture: Artworks::YoutubeImages fetches no other.
    sig { params(data: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
    def thumbnail(data)
      url = data["thumbnail"].to_s
      URI.parse(url).then { |uri| uri.scheme == "https" && uri.host == "i.ytimg.com" ? url : nil }
    rescue URI::InvalidURIError
      nil
    end

    # A channel made from a folder learns its YouTube id from its first
    # identified video — unless another channel already has that id.
    sig { params(details: Channels::Sidecars::Details).void }
    def claim_channel(details)
      channel = @video.channel
      youtube_id = details.channel_youtube_id
      return if channel.nil? || channel.youtube_id.present? || youtube_id.nil? || !youtube_id.match?(Urls::CHANNEL_ID)
      return if Channel.unscoped.where(library_id: channel.library_id, youtube_id: youtube_id).exists?

      channel.youtube_id = youtube_id
      channel.handle ||= details.channel_handle
      channel.url ||= Urls.channel_url(youtube_id)
      channel.assign_unlocked(title: details.channel_title) if details.channel_title.present? && channel.title == channel.folder
      channel.save!
      IdentifyChannelVideosJob.perform_later(channel.id)
    end
  end
end

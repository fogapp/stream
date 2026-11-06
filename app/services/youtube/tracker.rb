# typed: strict
# frozen_string_literal: true

module Youtube
  # Turns a resolved link into what Stream will fetch (PROPOSAL §5.4): a
  # tracked channel that's polled from now on, or one-off downloads of a
  # video or a playlist's videos into their channels' folders.
  class Tracker
    extend T::Sig

    class NoDownloadFolder < StandardError; end

    # What a pasted video that Stream already knew is fetched again from:
    # it isn't on disk. One that's there or on its way is only kept.
    GONE = T.let([ YoutubeDownload::State::Failed, YoutubeDownload::State::Skipped, YoutubeDownload::State::Removed ].freeze,
      T::Array[YoutubeDownload::State])

    RULES = T.let(%i[backfill backfill_count backfill_since keep_last skip_shorts skip_live title_filter max_height
      poll_every_hours].freeze, T::Array[Symbol])

    sig { params(household: Household).void }
    def initialize(household)
      @household = household
      @library = T.let(
        Library.unscoped.where(household_id: household.id, kind: Library::Kind::Channels.serialize).where.not(download_root: nil).first ||
          raise(NoDownloadFolder, "Choose where YouTube downloads go first, in Settings › YouTube"),
        Library
      )
    end

    sig { params(preview: Resolver::Preview, rules: T::Hash[Symbol, T.untyped]).returns(Channel) }
    def track(preview, rules = {})
      info = preview.channel || raise(Urls::Invalid, "That link has no channel to track")
      channel = ensure_channel(info)
      channel.assign_attributes(rules.select { |key, _| RULES.include?(key) }.merge(tracked: true, last_poll_error: nil))
      channel.save!
      PollChannelJob.perform_later(channel.id)
      channel
    end

    # A video or a playlist: each video into its own channel's folder, made
    # if Stream doesn't know it yet (and not followed). A single video was
    # asked for by name: it's kept whatever the keep-last rule says, fetched
    # whatever the channel's rules say, and fetched again if it went before.
    sig { params(preview: Resolver::Preview).returns(T::Array[YoutubeDownload]) }
    def download(preview)
      by_hand = preview.kind == Urls::Kind::Video
      channels = T.let({}, T::Hash[String, Channel])
      preview.videos.filter_map do |video|
        channel_id = video["channel_id"].to_s
        next unless channel_id.match?(Urls::CHANNEL_ID)

        known = preview.channel&.youtube_id == channel_id ? preview.channel : nil
        channel = channels[channel_id] ||= ensure_channel(known || Resolver::ChannelInfo.new(youtube_id: channel_id, title: channel_id))
        queue(channel, video["id"].to_s, video["title"], by_hand: by_hand)
      end
    end

    sig do
      params(channel: Channel, youtube_id: String, title: T.nilable(String), by_hand: T::Boolean).returns(T.nilable(YoutubeDownload))
    end
    def queue(channel, youtube_id, title, by_hand: false)
      return nil unless youtube_id.match?(Urls::VIDEO_ID)
      # Already on disk, put there by hand: a second copy would be a second video.
      return nil if by_hand && on_disk_by_hand?(channel, youtube_id)

      row = YoutubeDownload.find_or_create_by!(channel: channel, youtube_id: youtube_id) do |created|
        created.household_id = @household.id
        created.title = title
        created.by_hand = by_hand
        created.kept = by_hand
      end
      if by_hand && !row.previously_new_record?
        return keep(row) unless GONE.include?(row.state_enum)

        row.fetch_again!(kept: true)
        return row
      end
      DownloadVideoJob.perform_later(row.id) if row.state_enum == YoutubeDownload::State::Queued && row.attempts.zero?
      row
    rescue ActiveRecord::RecordNotUnique
      YoutubeDownload.find_by(channel: channel, youtube_id: youtube_id)
    end

    private

    sig { params(row: YoutubeDownload).returns(YoutubeDownload) }
    def keep(row)
      row.update!(kept: true, by_hand: true)
      row
    end

    sig { params(channel: Channel, youtube_id: String).returns(T::Boolean) }
    def on_disk_by_hand?(channel, youtube_id)
      !YoutubeDownload.exists?(channel: channel, youtube_id: youtube_id) &&
        Video.unscoped.exists?(channel_id: channel.id, youtube_id: youtube_id)
    end

    # The channel's folder under the download root: its name, made safe for
    # a Windows/SMB share, with its id if another channel has the name. A
    # folder of that name put there by hand, which no YouTube id has claimed
    # yet, is this channel: its videos and the new ones are one channel.
    sig { params(info: Resolver::ChannelInfo).returns(Channel) }
    def ensure_channel(info)
      existing = Channel.unscoped.find_by(library_id: @library.id, youtube_id: info.youtube_id) ||
                 Channel.unscoped.find_by(library_id: @library.id, folder: self.class.folder_name(info.title), youtube_id: nil)
      if existing
        ChannelLink.apply(existing, info)
        return existing
      end

      folder = self.class.folder_name(info.title)
      folder = "#{folder} [#{info.youtube_id}]" if Channel.unscoped.exists?(library_id: @library.id, folder: folder)
      channel = Channel.create!(household_id: @household.id, library: @library, folder: folder, title: info.title,
        youtube_id: info.youtube_id, handle: info.handle, description: info.description, url: Urls.channel_url(info.youtube_id),
        avatar_url: info.avatar_url, banner_url: info.banner_url)
      SyncArtworkJob.perform_later("Channel", channel.id)
      channel
    end

    sig { params(title: String).returns(String) }
    def self.folder_name(title)
      cleaned = title.gsub(%r{[<>:"/\\|?*\x00-\x1f]}, " ").squeeze(" ").strip.delete_suffix(".").first(80)
      cleaned.presence || "Channel"
    end
  end
end

# typed: strict
# frozen_string_literal: true

module Catalog
  # Files a probed video under its channel (PROPOSAL §5.4): the channel is
  # its folder; the details come from whatever sits beside it.
  class VideoMatcher
    extend T::Sig

    sig { params(file: MediaFile, library: Library, parsed: Media::NameParser::Parsed, folder_path: T.nilable(String)).void }
    def initialize(file, library, parsed, folder_path)
      @file = file
      @library = library
      @parsed = parsed
      @folder_path = folder_path
    end

    sig { void }
    def call
      details = Channels::Sidecars.read(@file.path, @file.probe)
      channel = find_channel(details)
      video = find_video(channel, details)
      # What YouTube said of an identified video beats anything but an
      # info.json beside the file.
      unless video.source_enum == Video::Source::Youtube && details.source != Video::Source::InfoJson
        video.assign_unlocked(
          title: details.title || @parsed.title, description: details.description,
          upload_date: details.upload_date || @parsed.air_date || @file.mtime.to_date,
          tags: details.tags, chapters: details.chapters, url: details.url || youtube_url(details)
        )
        video.source = details.source.serialize
      end
      video.youtube_id ||= details.youtube_id || @parsed.youtube_id
      video.identity = Video::Identity::Identified.serialize if video.youtube_id
      video.save!

      Edition.where(media_file: @file).where.not(playable: video).delete_all
      Edition.find_or_create_by!(media_file: @file, playable: video)
      SyncArtworkJob.perform_later("Video", video.id)
      NotifyArrivalsJob.set(wait: NotifyArrivalsJob::WAIT).perform_later("channel", channel.id) if video.previously_new_record?
      FetchSponsorSegmentsJob.perform_later(video.id) if @library.sponsorblock && video.youtube_id && video.sponsorblock_checked_at.nil?
    end

    private

    sig { params(details: Channels::Sidecars::Details).returns(T.nilable(String)) }
    def youtube_url(details)
      id = details.youtube_id || @parsed.youtube_id
      id && "https://www.youtube.com/watch?v=#{id}"
    end

    # One row per channel folder; the first file that knows the channel's
    # real name and id fills them in.
    sig { params(details: Channels::Sidecars::Details).returns(Channel) }
    def find_channel(details)
      folder = @parsed.show_folder.presence || "Unsorted"
      channel = Channel.unscoped.find_by(library_id: @library.id, folder: folder)
      channel ||= begin
        created = Channel.create!(household_id: @file.household_id, library: @library, folder: folder, title: folder)
        SyncArtworkJob.perform_later("Channel", created.id)
        created
      rescue ActiveRecord::RecordNotUnique
        Channel.unscoped.find_by!(library_id: @library.id, folder: folder)
      end
      fill_channel(channel, details)
      channel
    end

    sig { params(channel: Channel, details: Channels::Sidecars::Details).void }
    def fill_channel(channel, details)
      info = @folder_path && channel.description.nil? ? Channels::Sidecars.channel_info(@folder_path) : nil
      title = info&.dig("channel") || info&.dig("title") || details.channel_title
      channel.assign_unlocked(title: title) if title.present? && channel.title == channel.folder
      channel.youtube_id ||= info&.dig("channel_id") || details.channel_youtube_id
      channel.handle ||= info&.dig("uploader_id").then { |id| id.to_s.start_with?("@") ? id : nil } || details.channel_handle
      channel.url ||= info&.dig("channel_url") || details.channel_url
      channel.assign_unlocked(description: info["description"].presence) if info
      channel.save! if channel.changed?
    end

    sig { params(channel: Channel, details: Channels::Sidecars::Details).returns(Video) }
    def find_video(channel, details)
      current = Edition.find_by(media_file: @file, playable_type: "Video")&.playable
      return current if current.is_a?(Video) && current.channel_id == channel.id

      youtube_id = details.youtube_id || @parsed.youtube_id
      existing = youtube_id && Video.unscoped.find_by(library_id: @library.id, youtube_id: youtube_id)
      existing || Video.new(household_id: @file.household_id, library: @library, channel: channel,
        title: details.title || @parsed.title, source: details.source.serialize)
    end
  end
end

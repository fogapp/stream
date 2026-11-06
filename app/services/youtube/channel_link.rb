# typed: strict
# frozen_string_literal: true

module Youtube
  # Which YouTube channel a channel is, and what YouTube says of it
  # (PROPOSAL §5.4): its id, handle, pictures, link and description. Add
  # channel does this as it starts tracking; Link to YouTube does it alone,
  # for a folder of videos put there by hand that nothing should download
  # into.
  module ChannelLink
    extend T::Sig

    # A name taken from the folder (or a bare id) gives way to YouTube's; one
    # a person typed, or locked, stays.
    sig { params(channel: Channel, info: Resolver::ChannelInfo).void }
    def self.apply(channel, info)
      channel.youtube_id ||= info.youtube_id
      channel.assign_unlocked(title: info.title) if channel.title == channel.folder || channel.title == info.youtube_id
      channel.assign_attributes(handle: info.handle || channel.handle, avatar_url: info.avatar_url || channel.avatar_url,
        banner_url: info.banner_url || channel.banner_url, url: channel.url || Urls.channel_url(info.youtube_id))
      channel.assign_unlocked(description: info.description) if info.description
      return unless channel.changed?

      channel.save!
      SyncArtworkJob.perform_later("Channel", channel.id)
    end
  end
end

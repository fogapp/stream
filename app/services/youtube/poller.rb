# typed: strict
# frozen_string_literal: true

module Youtube
  # Asks YouTube what a tracked channel has posted and queues what the
  # rules want (PROPOSAL §5.4). The first poll is the backfill; after that
  # only what's newer than the newest video it already knows is queued, so
  # a later poll never reaches back past what the backfill chose to leave.
  class Poller
    extend T::Sig

    # How many of the newest to look at once the backfill is done.
    RECENT = 50
    # How far back a "newest N" backfill looks for N whose titles match the
    # channel's filter.
    FILTERED_LOOKBACK = 500

    sig { params(channel: Channel).void }
    def initialize(channel)
      @channel = channel
    end

    sig { void }
    def call
      youtube_id = @channel.youtube_id
      raise Urls::Invalid, "#{@channel.title} has no YouTube id to poll" if youtube_id.nil?

      household = T.must(Household.find_by(id: @channel.household_id))
      tracker = Tracker.new(household)
      # Videos already on disk by hand are found on YouTube first, so the
      # backfill doesn't fetch them a second time.
      Identifier.new(@channel).call
      known = known_ids
      backfill = @channel.last_polled_at.nil?
      tabs.each do |tab|
        queued = 0
        entries(youtube_id, tab).each do |entry|
          id = entry["id"].to_s
          # A tab lists newest first: past the first known video is old news.
          break if !backfill && known.include?(id)
          break if backfill && queued == wanted_from_backfill
          next if known.include?(id)
          # Not recorded: a video the filter passes over is looked at again
          # only if it's newer than what's known, so a changed filter
          # applies from then on.
          next unless @channel.wants_title?(entry["title"])

          tracker.queue(@channel, id, entry["title"])
          known << id
          queued += 1
        end
      end
      @channel.update!(last_polled_at: Time.current, last_poll_error: nil)
      Retention.new(@channel).call
    rescue YtDlp::Error, Urls::Invalid, Tracker::NoDownloadFolder => e
      @channel.update!(last_polled_at: Time.current, last_poll_error: e.message.truncate(300))
      Activity.record(source: "youtube", event: "channel.poll_failed", severity: Activity::Severity::Warn, subject: @channel,
        household_id: @channel.household_id, summary: "Couldn't check #{@channel.title} for new videos: #{e.message.truncate(200)}")
    end

    private

    sig { returns(T::Array[String]) }
    def tabs
      [ "videos", @channel.skip_shorts ? nil : "shorts", @channel.skip_live ? nil : "streams" ].compact
    end

    sig { params(youtube_id: String, tab: String).returns(T::Array[T::Hash[String, T.untyped]]) }
    def entries(youtube_id, tab)
      limit = limit_for_this_poll
      data = YtDlp.tab_listing(youtube_id, tab, limit ? [ "--playlist-end", limit.to_s ] : [])
      Array(data["entries"]).select { |entry| entry["id"].to_s.match?(Urls::VIDEO_ID) }
    end

    sig { returns(T.nilable(Integer)) }
    def limit_for_this_poll
      return RECENT unless @channel.last_polled_at.nil?

      wanted = wanted_from_backfill
      wanted && @channel.title_filter ? [ wanted, FILTERED_LOOKBACK ].max : wanted
    end

    # How many videos a tab's backfill queues; nil for all of them.
    sig { returns(T.nilable(Integer)) }
    def wanted_from_backfill
      backfill = @channel.backfill_enum
      case backfill
      when Channel::Backfill::Recent then @channel.backfill_count
      when Channel::Backfill::All, Channel::Backfill::Since then nil
      else T.absurd(backfill)
      end
    end

    # Everything already fetched, queued or refused, and anything already
    # on disk for this channel (put there by hand, say).
    sig { returns(T::Set[String]) }
    def known_ids
      (@channel.youtube_downloads.pluck(:youtube_id) + Video.unscoped.where(channel_id: @channel.id).where.not(youtube_id: nil).pluck(:youtube_id))
        .to_set
    end
  end
end

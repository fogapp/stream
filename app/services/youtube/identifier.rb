# typed: strict
# frozen_string_literal: true

module Youtube
  # Works out which YouTube video each of a channel's hand-placed videos is
  # (PROPOSAL §5.4): files put in a channel's folder without an info.json
  # or an [id] in their names. The channel's own list of videos is asked for
  # once, and each file is matched against it by title and length.
  #
  # Only a sure match is taken — the title exactly as yt-dlp would have
  # written the file's name, or nearly so, and the same length to within a
  # couple of seconds — and only when nothing else on the channel fits as
  # well. Anything less leaves the closest few for a person to pick from on
  # the video's page. A fuzzy title alone is never enough: "STAR WARS PORNO"
  # and "STAR WARS JESUS" are 80% alike and different videos.
  class Identifier
    extend T::Sig

    TABS = T.let(%w[videos streams shorts].freeze, T::Array[String])
    # Lengths this close are the same video, remuxed or trimmed by a frame.
    SAME_LENGTH = 2.0
    # A title this alike, at the same length, is the same video retitled.
    NEAR_TITLE = 0.9
    # Below this, a candidate isn't worth a person's look — however close
    # its length: among a few thousand videos, a fifteen-minute one has
    # dozens of neighbours within two seconds.
    CANDIDATE_TITLE = 0.5
    MAX_CANDIDATES = 5
    # What a candidate keeps for the video's page.
    SAVED = T.let(%w[youtube_id title duration_seconds score reasons].freeze, T::Array[String])

    # yt-dlp's stand-ins for what a file name can't hold.
    FILENAME_STAND_INS = T.let({ "⧸" => "/", "⧹" => "\\" }.freeze, T::Hash[String, String])

    class Counts < T::Struct
      prop :identified, Integer, default: 0
      prop :needs_review, Integer, default: 0
      prop :not_found, Integer, default: 0
    end

    sig { params(channel: Channel).void }
    def initialize(channel)
      @channel = channel
    end

    sig { returns(T::Boolean) }
    def pending? = unchecked.exists?

    sig { returns(Counts) }
    def call
      counts = Counts.new
      youtube_id = @channel.youtube_id
      return counts if youtube_id.nil? || !pending?

      claimed = Video.unscoped.where(library_id: @channel.library_id).where.not(youtube_id: nil).pluck(:youtube_id).to_set
      entries = listing(youtube_id).reject { |entry| claimed.include?(entry["id"]) }
      unchecked.includes(:media_files).find_each do |video|
        judge(video, entries, claimed, counts)
      end
      record(counts)
      counts
    end

    # A title as it reads in yt-dlp's file names and as YouTube has it now,
    # made comparable: full-width stand-ins folded back, case and spacing
    # ignored.
    sig { params(title: String).returns(String) }
    def self.strict(title)
      folded = title.unicode_normalize(:nfkc).gsub(/[⧸⧹]/, FILENAME_STAND_INS)
      folded.gsub(/\s+/, " ").strip.downcase
    end

    private

    sig { returns(ActiveRecord::Relation) }
    def unchecked = Video.unscoped.where(channel_id: @channel.id, youtube_id: nil, identity: Video::Identity::Unchecked.serialize)

    # Every video, live and Short the channel lists, in one go each.
    sig { params(youtube_id: String).returns(T::Array[T::Hash[String, T.untyped]]) }
    def listing(youtube_id)
      TABS.flat_map do |tab|
        data = YtDlp.tab_listing(youtube_id, tab)
        picture_channel(data) if tab == "videos"
        Array(data["entries"]).select { |entry| entry["id"].to_s.match?(Urls::VIDEO_ID) && entry["title"].present? }
      end.uniq { |entry| entry["id"] }
    end

    # A channel made from a folder has no pictures until YouTube is asked;
    # the list of its videos comes with them.
    sig { params(data: T::Hash[String, T.untyped]).void }
    def picture_channel(data)
      info = Resolver.channel_info(data)
      return if info.nil? || info.youtube_id != @channel.youtube_id

      @channel.avatar_url ||= info.avatar_url
      @channel.banner_url ||= info.banner_url
      @channel.handle ||= info.handle
      @channel.assign_unlocked(description: info.description) if @channel.description.nil? && info.description
      return unless @channel.changed?

      @channel.save!
      SyncArtworkJob.perform_later("Channel", @channel.id)
    end

    sig do
      params(video: Video, entries: T::Array[T::Hash[String, T.untyped]], claimed: T::Set[String], counts: Counts).void
    end
    def judge(video, entries, claimed, counts)
      file = video.media_files.max_by { |each| each.size.to_i }
      name = strict(file ? File.basename(file.path, ".*") : video.title)
      length = file&.duration_seconds
      scored = entries.reject { |entry| claimed.include?(entry["id"]) }.filter_map { |entry| score(entry, name, length) }
        .sort_by { |candidate| -candidate.fetch("score") }

      sure = sure_of(scored)
      if sure && identify(video, sure)
        claimed << sure.fetch("youtube_id")
        counts.identified += 1
        return
      end

      candidates = scored.first(MAX_CANDIDATES).map { |candidate| candidate.select { |key, _| SAVED.include?(key) } }
      identity = candidates.any? ? Video::Identity::NeedsReview : Video::Identity::NotFound
      video.update!(identity: identity.serialize, youtube_candidates: candidates)
      identity == Video::Identity::NeedsReview ? counts.needs_review += 1 : counts.not_found += 1
    end

    # A title made strict once, however many videos it's held against.
    sig { params(title: String).returns(String) }
    def strict(title)
      (@strict ||= T.let({}, T.nilable(T::Hash[String, String])))[title] ||= self.class.strict(title)
    end

    # `name` is the video's, already strict.
    sig do
      params(entry: T::Hash[String, T.untyped], name: String, length: T.nilable(Float)).returns(T.nilable(T::Hash[String, T.untyped]))
    end
    def score(entry, name, length)
      title = entry["title"].to_s
      theirs = strict(title)
      exact = theirs == name
      alike = exact ? 1.0 : Catalog::Scorer.similarity(name, theirs)
      their_length = entry["duration"]&.to_f
      gap = length && their_length ? (length - their_length).abs : nil
      same_length = !gap.nil? && gap <= SAME_LENGTH
      return nil if alike < CANDIDATE_TITLE

      reasons = [ exact ? "title matches" : "title #{(alike * 100).round}% alike" ]
      reasons << if gap.nil? then "length unknown"
      elsif same_length then "same length"
      else "length differs by #{gap.round}s"
      end
      length_fit = if gap.nil? then 0.5 elsif same_length then 1.0 elsif gap <= 30 then 0.5 else 0.0 end
      {
        "youtube_id" => entry["id"], "title" => title, "duration_seconds" => their_length,
        "score" => ((alike * 0.7) + (length_fit * 0.3)).round(3), "reasons" => reasons,
        "alike" => alike, "exact" => exact, "same_length" => same_length, "length_known" => !gap.nil?
      }
    end

    # The one candidate that can only be this video: its exact title (at
    # the same length, when both lengths are known), or nearly its title at
    # the same length — with no other candidate as good.
    sig { params(scored: T::Array[T::Hash[String, T.untyped]]).returns(T.nilable(T::Hash[String, T.untyped])) }
    def sure_of(scored)
      exact = scored.select { |candidate| candidate["exact"] }
      if exact.any?
        return nil unless exact.one?

        only = T.must(exact.first)
        return only if only["same_length"] || !only["length_known"]

        return nil
      end
      near = scored.select { |candidate| candidate["same_length"] && candidate.fetch("alike") >= NEAR_TITLE }
      near.one? ? near.first : nil
    end

    # False when another video took the id first (two copies of one video).
    sig { params(video: Video, candidate: T::Hash[String, T.untyped]).returns(T::Boolean) }
    def identify(video, candidate)
      youtube_id = candidate.fetch("youtube_id")
      video.update!(youtube_id: youtube_id, identity: Video::Identity::Identified.serialize, youtube_candidates: [],
        url: video.url || Urls.video_url(youtube_id))
      HydrateVideoJob.perform_later(video.id)
      true
    rescue ActiveRecord::RecordNotUnique
      video.reload
      false
    end

    sig { params(counts: Counts).void }
    def record(counts)
      return if counts.identified.zero? && counts.needs_review.zero? && counts.not_found.zero?

      parts = { "identified" => counts.identified, "to check by hand" => counts.needs_review, "not found" => counts.not_found }
        .reject { |_, count| count.zero? }.map { |label, count| "#{count} #{label}" }
      Activity.record(source: "youtube", event: "channel.identified", subject: @channel, household_id: @channel.household_id,
        summary: "#{@channel.title}: #{parts.join(', ')} on YouTube")
    end
  end
end

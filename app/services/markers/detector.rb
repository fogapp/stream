# typed: strict
# frozen_string_literal: true

module Markers
  # Markers for files (PROPOSAL §5.5). Chapters first — a file that names
  # its intro or credits is taken at its word. For a season of episodes,
  # the rest comes from audio: each episode against its neighbour, the
  # shared opening minutes being the intro and the shared closing ones the
  # credits; and a recap is the montage at the start of an episode made of
  # clips from the ones before it.
  module Detector
    extend T::Sig

    INTRO_MAX = 150.0
    CREDITS_MAX = 420.0
    # A recap: clips of at least 3 s from earlier episodes, no more than
    # 10 s apart, adding up to at least 12 s, starting in the first 90 s.
    RECAP_CLIP_MIN = 3.0
    RECAP_GAP = 10.0
    RECAP_MIN = 12.0
    RECAP_STARTS_WITHIN = 90.0
    RECAP_LOOKBACK = 3

    CHAPTER_KINDS = T.let({
      /\A(intro|opening|op|opening credits|title sequence)\b/i => Marker::Kind::Intro,
      /\A(recap|previously)\b/i => Marker::Kind::Recap,
      /\A(credits|end credits|ending|ed|closing credits)\b/i => Marker::Kind::Credits
    }.freeze, T::Hash[Regexp, Marker::Kind])

    sig { params(file: MediaFile).returns(T::Array[Marker]) }
    def self.from_chapters(file)
      Array(file.chapters).filter_map do |chapter|
        kind = CHAPTER_KINDS.find { |pattern, _| chapter["title"].to_s.strip.match?(pattern) }&.last
        next nil if kind.nil?

        Marker.offer(file, kind, start: chapter["start"].to_f, finish: chapter["end"].to_f, source: Marker::Source::Chapter)
      end
    end

    # A file's fingerprints, read once for as long as a season is worked on.
    Prints = T.type_alias { T::Hash[[ String, AudioFingerprint::Segment ], AudioFingerprint] }

    # A season's episodes are filed one by one, each asking for the season:
    # the comparison waits for its neighbours, and those that arrive before
    # it starts share it. One that arrives later asks again.
    QUEUE_WAIT = T.let(5.minutes, ActiveSupport::Duration)

    sig { params(show: Show, season_number: Integer, priority: Integer).void }
    def self.detect_later(show, season_number, priority:)
      return unless Rails.cache.write("stream/markers/queued/#{show.id}/#{season_number}", true, unless_exist: true, expires_in: QUEUE_WAIT)

      DetectMarkersJob.set(wait: QUEUE_WAIT, priority: priority).perform_later(show.id, season_number)
    end

    # Every episode of one season with a readable file. A season's episodes
    # each ask for this as they are filed, so a season already compared with
    # exactly these files is left alone.
    sig { params(show: Show, season_number: Integer, hold: T.nilable(ToolRunner::Hold)).returns(Integer) }
    def self.detect_season(show, season_number, hold: nil)
      files = season_files(show, season_number)
      files.each { |file| from_chapters(file) }
      return 0 if files.size < 2

      before = season_number > 1 ? season_files(show, season_number - 1, last: RECAP_LOOKBACK) : []
      compared = signature(files + before)
      return 0 if Rails.cache.read(settled_key(show.id, season_number)) == compared

      found = 0
      prints = cached_ends(files + before)
      files.each_with_index do |file, index|
        neighbour = files[index + 1] || files[index - 1]
        next if neighbour.nil? || neighbour == file

        AnalysisRun.track(file, AnalysisRun::Step::Markers, tool_version: "chromaprint") do
          found += 1 if detect(file, neighbour, AudioFingerprint::Segment::Head, Marker::Kind::Intro, INTRO_MAX, prints, hold)
          found += 1 if detect(file, neighbour, AudioFingerprint::Segment::Tail, Marker::Kind::Credits, CREDITS_MAX, prints, hold)
        end
      end
      # With intros and credits known (so they aren't taken for recap
      # clips), each episode against the ones before it.
      themes = Marker.where(media_file_id: (files + before).map(&:id), kind: [ Marker::Kind::Intro, Marker::Kind::Credits ].map(&:serialize))
        .group_by(&:media_file_id)
      files.each_with_index do |file, index|
        earlier = files.first(index).last(RECAP_LOOKBACK)
        earlier = before if earlier.empty?
        if earlier.any?
          AnalysisRun.track(file, AnalysisRun::Step::Markers, tool_version: "chromaprint") do
            found += 1 if detect_recap(file, earlier, themes, prints, hold)
          end
        end
        # A whole episode's fingerprint is the big one: let go of it once no
        # later episode looks back this far.
        prints.delete([ T.must(files[index - RECAP_LOOKBACK]).id, AudioFingerprint::Segment::Whole ]) if index >= RECAP_LOOKBACK
      end
      Rails.cache.write(settled_key(show.id, season_number), compared)
      found
    end

    # Asked for by a person: compare the season again whatever was done before.
    sig { params(show_id: String, season_number: Integer).void }
    def self.forget_season(show_id, season_number)
      Rails.cache.delete(settled_key(show_id, season_number))
    end

    sig { params(show_id: String, season_number: Integer).returns(String) }
    def self.settled_key(show_id, season_number) = "stream/markers/season/#{show_id}/#{season_number}"

    # The files a comparison was made of: a new, replaced or changed one
    # makes it a different season.
    sig { params(files: T::Array[MediaFile]).returns(String) }
    def self.signature(files)
      Digest::SHA256.hexdigest(files.map { |file| [ file.id, file.size, file.mtime.to_i ].join(":") }.sort.join("|"))
    end

    # The openings and endings already read of these files, in one query
    # rather than one per file and end. A whole episode's is left to be read
    # when it's wanted: it's the big one.
    sig { params(files: T::Array[MediaFile]).returns(Prints) }
    def self.cached_ends(files)
      AudioFingerprint.where(media_file_id: files.map(&:id), segment: [ AudioFingerprint::Segment::Head, AudioFingerprint::Segment::Tail ].map(&:serialize))
        .to_h { |print| [ [ print.media_file_id, print.segment_enum ], print ] }
    end

    # The largest readable file of each episode of a season (or of its last
    # few), in episode order.
    sig { params(show: Show, season_number: Integer, last: T.nilable(Integer)).returns(T::Array[MediaFile]) }
    def self.season_files(show, season_number, last: nil)
      episode_ids = show.episodes.where(season_number: season_number).order(:episode_number).pluck(:id)
      episode_ids = episode_ids.last(last) if last
      editions = Edition.where(playable_type: "Episode", playable_id: episode_ids).pluck(:playable_id, :media_file_id)
      readable = MediaFile.playable.where(id: editions.map(&:last).uniq).includes(:media_streams).index_by(&:id)
      of_episode = editions.group_by(&:first).transform_values { |pairs| pairs.filter_map { |_, file_id| readable[file_id] } }
      episode_ids.filter_map { |id| of_episode[id]&.max_by(&:size) }.uniq
    end

    sig do
      params(file: MediaFile, earlier: T::Array[MediaFile], themes: T::Hash[String, T::Array[Marker]], prints: Prints,
        hold: T.nilable(ToolRunner::Hold)).returns(T.nilable(Marker))
    end
    def self.detect_recap(file, earlier, themes, prints, hold = nil)
      head = fingerprint(file, AudioFingerprint::Segment::Head, prints, hold)
      intro = themes.fetch(file.id, []).find { |marker| marker.kind_enum == Marker::Kind::Intro }
      clips = earlier.flat_map do |other|
        whole = fingerprint(other, AudioFingerprint::Segment::Whole, prints, hold)
        skip = themes.fetch(other.id, [])
        Matcher.all(head.points, whole.points, min: RECAP_CLIP_MIN, max: 120.0, shifts: 40)
          .reject { |match| skip.any? { |marker| overlaps?(match.b, marker) } }
          .filter_map { |match| before_intro(match.a, intro) }
      end
      region = merge(clips).find { |span, matched| span.start <= RECAP_STARTS_WITHIN && matched >= RECAP_MIN }
      return nil if region.nil?

      span, matched = region
      # A recap that starts in the first few seconds starts the episode.
      start = span.start < 5 ? 0.0 : span.start
      Marker.offer(file, Marker::Kind::Recap, start: start, finish: span.finish, source: Marker::Source::Detected,
        confidence: (matched / (span.finish - start)).clamp(0.0, 1.0).round(3))
    end

    # Clips close together as regions, each with how much of it matched.
    sig { params(clips: T::Array[Matcher::Span]).returns(T::Array[[ Matcher::Span, Float ]]) }
    def self.merge(clips)
      regions = T.let([], T::Array[[ Matcher::Span, Float ]])
      clips.sort_by(&:start).each do |clip|
        last = regions.last
        if last && clip.start - last[0].finish <= RECAP_GAP
          merged = Matcher::Span.new(start: last[0].start, finish: [ last[0].finish, clip.finish ].max)
          regions[-1] = [ merged, last[1] + [ clip.finish - [ clip.start, last[0].finish ].max, 0.0 ].max ]
        else
          regions << [ clip, clip.duration ]
        end
      end
      regions
    end

    # A recap runs up to the intro: a clip reaching into it (the two are
    # often back to back, and the intro's found edge can be a second or two
    # early) is cut at it; one inside it isn't a recap clip.
    sig { params(span: Matcher::Span, intro: T.nilable(Marker)).returns(T.nilable(Matcher::Span)) }
    def self.before_intro(span, intro)
      return span if intro.nil? || span.finish <= intro.start_seconds
      return nil if span.start >= intro.start_seconds

      cut = Matcher::Span.new(start: span.start, finish: intro.start_seconds)
      cut.duration >= RECAP_CLIP_MIN ? cut : nil
    end

    sig { params(span: Matcher::Span, marker: Marker).returns(T::Boolean) }
    def self.overlaps?(span, marker) = span.start < marker.end_seconds && span.finish > marker.start_seconds

    sig do
      params(file: MediaFile, segment: AudioFingerprint::Segment, prints: Prints, hold: T.nilable(ToolRunner::Hold))
        .returns(AudioFingerprint)
    end
    def self.fingerprint(file, segment, prints, hold = nil)
      prints[[ file.id, segment ]] ||= Fingerprinter.for(file, segment, hold: hold)
    end

    sig do
      params(file: MediaFile, other: MediaFile, segment: AudioFingerprint::Segment, kind: Marker::Kind, max: Float, prints: Prints,
        hold: T.nilable(ToolRunner::Hold)).returns(T.nilable(Marker))
    end
    def self.detect(file, other, segment, kind, max, prints, hold = nil)
      mine = fingerprint(file, segment, prints, hold)
      theirs = fingerprint(other, segment, prints, hold)
      # The theme is the first shared stretch of the opening minutes; the
      # credits music the last of the closing ones.
      matches = Matcher.all(mine.points, theirs.points, max: max)
      match = kind == Marker::Kind::Credits ? matches.last : matches.first
      return nil if match.nil?

      start = mine.offset_seconds + match.a.start
      finish = mine.offset_seconds + match.a.finish
      # Credits run to the end; the matched music may stop a little before.
      finish = file.duration_seconds.to_f if kind == Marker::Kind::Credits && file.duration_seconds.to_f - finish < 20
      Marker.offer(file, kind, start: start, finish: finish, source: Marker::Source::Detected, confidence: match.confidence)
    end
  end
end

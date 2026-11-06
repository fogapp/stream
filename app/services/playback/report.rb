# typed: strict
# frozen_string_literal: true

module Playback
  # The Playback decisions page (PROPOSAL §7.6): what happened when people
  # pressed Play, in plain words, and which files make a device convert
  # video — the expensive case worth doing something about.
  module Report
    extend T::Sig

    # A next step, when there is one, for a session's verdict.
    sig { params(decision: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
    def self.fix_hint(decision)
      case decision["method"]
      when "remux" then "Nothing to fix: repackaging is instant and lossless."
      when "audio_transcode" then "Nothing to fix: only the sound is converted, which costs almost nothing."
      when "video_transcode"
        if decision.dig("video", "tonemap")
          "Plays as-is on a screen that shows HDR (Safari on an XDR Mac, an HDR TV)."
        else
          "Optimize this file (on its file page) and it plays as-is here from then on."
        end
      end
    end

    # This week's split of methods, and the reasons behind anything that
    # wasn't direct play, most common first.
    sig { params(since: ActiveSupport::TimeWithZone).returns(T::Hash[Symbol, T.untyped]) }
    def self.summary(since:)
      sessions = PlaybackSession.watched.where(started_at: since..)
      counts = sessions.group(:method).count
      reasons = T.let(sessions.where.not(method: PlaybackSession::Method::Direct.serialize)
        .group(Arel.sql("decision->>'summary'")).order(Arel.sql("count(*) DESC")).limit(3).count, T.untyped)
      troubles = PlaybackEvent.joins(:playback_session).merge(sessions).where(kind: TROUBLES.map(&:serialize)).group(:kind).count
      {
        since: since, total: counts.values.sum,
        methods: PlaybackSession::Method.values.to_h { |method| [ method.serialize, counts.fetch(method.serialize, 0) ] },
        top_reasons: reasons.map { |summary, count| { summary: summary, count: count } },
        channel_changes: channel_changes(since),
        program_changes: program_changes(since),
        startup: startup(since),
        seeks: seeks(since),
        stalls: troubles.fetch(PlaybackEvent::Kind::Stall.serialize, 0),
        recoveries: troubles.fetch(PlaybackEvent::Kind::Recovery.serialize, 0),
        errors: troubles.fetch(PlaybackEvent::Kind::Error.serialize, 0)
      }
    end

    TROUBLES = T.let([ PlaybackEvent::Kind::Stall, PlaybackEvent::Kind::Recovery, PlaybackEvent::Kind::Error ].freeze, T::Array[PlaybackEvent::Kind])

    # Events of one kind, from any session, since then.
    sig { params(kind: PlaybackEvent::Kind, since: ActiveSupport::TimeWithZone).returns(T.untyped) }
    def self.events(kind, since)
      PlaybackEvent.joins(:playback_session).merge(PlaybackSession.all).where(kind: kind.serialize, created_at: since..)
    end

    # What each recent device would get for one file.
    sig { params(file: MediaFile).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.device_decisions(file)
      max_height = Placement.max_height
      Device.recent.order(last_seen_at: :desc).map do |device|
        decision = Decision.new(file, device.capability_profile, max_height: max_height, device_name: device.name)
        { device: { id: device.id, name: device.name }, method: decision.method, summary: decision.summary }
      end
    end

    # Files some recent device would have to convert, with who and why, and
    # where each stands on being optimized.
    sig { params(household: Household).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.transcode_report(household)
      rows = needing_conversion(household)
      versions = OptimizedVersion.unscoped.where(media_file_id: rows.pluck(:media_file_id)).index_by(&:media_file_id)
      rows.map { |row| row.merge(optimized: versions[row[:media_file_id]]&.then { |version| OptimizedVersionSerializer.json(version) }) }
    end

    # Pressing Play to the first frame, per method (docs/PERF_PROPOSAL.md
    # › P1): how long it typically takes, and how long for nineteen in twenty.
    sig { params(since: ActiveSupport::TimeWithZone).returns(T::Hash[String, T::Hash[Symbol, T.untyped]]) }
    def self.startup(since)
      rows = events(PlaybackEvent::Kind::Startup, since).pluck("playback_sessions.method", Arel.sql("detail->>'ms'"))
      by_method = rows.group_by(&:first).transform_values { |pairs| milliseconds(pairs.map(&:last)) }
      PlaybackSession::Method.values.to_h { |method| [ method.serialize, spread(by_method.fetch(method.serialize, [])) ] }
    end

    # Seeks to somewhere nothing was buffered yet: the ones that wait on the
    # transcoder or the disk.
    sig { params(since: ActiveSupport::TimeWithZone).returns(T::Hash[Symbol, T.untyped]) }
    def self.seeks(since)
      rows = events(PlaybackEvent::Kind::Seek, since)
        .where("detail->>'ready' IS DISTINCT FROM 'true'").where("detail ? 'ms'").pluck(Arel.sql("detail->>'ms'"))
      spread(milliseconds(rows))
    end

    sig { params(values: T::Array[T.untyped]).returns(T::Array[Float]) }
    def self.milliseconds(values)
      values.filter_map { |ms| ms.to_s.match?(/\A\d+(\.\d+)?\z/) ? ms.to_f : nil }.sort
    end

    # How many, the median and the 95th percentile, of sorted times.
    sig { params(times: T::Array[Float]).returns(T::Hash[Symbol, T.untyped]) }
    def self.spread(times)
      { count: times.size, median_ms: percentile(times, 0.5), p95_ms: percentile(times, 0.95) }
    end

    sig { params(times: T::Array[Float], share: Float).returns(T.nilable(Integer)) }
    def self.percentile(times, share)
      return nil if times.empty?

      times[[ (times.size * share).ceil - 1, 0 ].max]&.round
    end

    # Grid channel changes (PROPOSAL §7.7): how many, and how long to the
    # first frame — tuned ahead or not.
    sig { params(since: ActiveSupport::TimeWithZone).returns(T::Hash[Symbol, T.untyped]) }
    def self.channel_changes(since)
      rows = events(PlaybackEvent::Kind::Tune, since).pluck(Arel.sql("detail->>'ms'"), Arel.sql("detail->>'ready'"))
      times = milliseconds(rows.map(&:first))
      ready = rows.count { |_, flag| flag.to_s == "true" }
      { count: times.size, ready: ready, median_ms: percentile(times, 0.5), p90_ms: percentile(times, 0.9) }
    end

    # Grid programs giving way to the next (PROPOSAL §7.7): how many,
    # how many were tuned ahead, how many only the watchdog noticed — a
    # stream that never said it ended — and how long to the next's first
    # frame. A change after a slate waited for its program on purpose, so
    # it isn't timed.
    sig { params(since: ActiveSupport::TimeWithZone).returns(T::Hash[Symbol, T.untyped]) }
    def self.program_changes(since)
      rows = events(PlaybackEvent::Kind::Transition, since)
        .pluck(Arel.sql("detail->>'ms'"), Arel.sql("detail->>'ready'"), Arel.sql("detail->>'via'"))
      timed = rows.reject { |_, _, via| via == "gap" }
      times = milliseconds(timed.map(&:first))
      {
        count: rows.size, ready: rows.count { |_, ready, _| ready.to_s == "true" }, watchdog: rows.count { |_, _, via| via == "watchdog" },
        median_ms: percentile(times, 0.5), p90_ms: percentile(times, 0.9)
      }
    end

    # Every readable file against every device seen this month, for the
    # Playback page and the nightly pass alike. all_devices marks a file no
    # recent device plays without converting — what the nightly pass
    # optimizes on its own (§5.5).
    sig { params(household: Household).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.needing_conversion(household)
      devices = Device.unscoped.where(household_id: household.id).recent.order(:id).to_a
      return [] if devices.empty?

      max_height = Placement.max_height
      inputs = conversion_inputs(household, devices, max_height)
      Rails.cache.fetch([ "stream/needing-conversion", household.id, Digest::SHA256.hexdigest(inputs.to_json) ], expires_in: 1.day) do
        note_changed_inputs(household, inputs)
        decide_conversions(household, devices, max_height)
      end
    end

    # Says which input sent needing_conversion back to work, so a key that
    # moves when nothing it stands for did can be found: the hourly pass
    # worked the whole library out afresh every run (Lucid, 2026-10-22: 15
    # batches, 10 s, every hour) with no file probed and no device changed.
    sig { params(household: Household, inputs: T::Hash[Symbol, T.untyped]).void }
    def self.note_changed_inputs(household, inputs)
      key = [ "stream/needing-conversion-inputs", household.id ]
      before = Rails.cache.read(key)
      Rails.cache.write(key, inputs, expires_in: 7.days)
      changed = before.is_a?(Hash) ? inputs.keys.reject { |name| before[name] == inputs[name] } : [ :nothing_cached ]
      Rails.logger.info("[needing_conversion] worked out afresh for household #{household.id}: #{changed.join(", ")} changed")
    end

    # What needing_conversion's answer depends on: which files are probed
    # and what their probes said, which of them have a ready optimized
    # version, the devices and what they play, the largest picture a
    # transcoder makes, and the code that decides. Not the files' updated_at:
    # loudness, subtitles and every other analysis step touch that, and keyed
    # on it the answer was worked out afresh every hour while a backlog ran
    # (Lucid, 2026-10-10). Its titles can lag a rename by up to a day.
    sig { params(household: Household, devices: T::Array[Device], max_height: Integer).returns(T::Hash[Symbol, T.untyped]) }
    def self.conversion_inputs(household, devices, max_height)
      files = MediaFile.unscoped.where(household_id: household.id, state: MediaFile::State::Probed.serialize)
        .pick(Arel.sql("COUNT(*)"), Arel.sql("MAX(probed_at)"), Arel.sql("BIT_XOR(hashtext(id::text))"))
      ready = OptimizedVersion.unscoped.where(household_id: household.id, state: OptimizedVersion::State::Ready.serialize)
        .pick(Arel.sql("COUNT(*)"), Arel.sql("MAX(updated_at)"))
      # JSON round-tripped, so it compares equal to the copy note_changed_inputs reads back.
      JSON.parse({ files: files, ready_versions: ready, devices: devices.map { |device| [ device.id, device.name, device.capabilities ] },
                   max_height: max_height, release: ENV.fetch("GIT_SHA", nil) }.to_json, symbolize_names: true)
    end

    # Every probed file's decision for every recent device: seconds of work
    # for a library, so it's done when something it depends on has changed
    # (conversion_inputs), not every time the page or the nightly pass asks.
    sig do
      params(household: Household, devices: T::Array[Device], max_height: Integer).returns(T::Array[T::Hash[Symbol, T.untyped]])
    end
    def self.decide_conversions(household, devices, max_height)
      rows = []
      MediaFile.unscoped.where(household_id: household.id, state: MediaFile::State::Probed.serialize)
        .includes(:media_streams, :optimized_version).find_each do |file|
        needing = devices.filter_map do |device|
          decision = Decision.new(file, device.capability_profile, max_height: max_height, device_name: device.name)
          { device: device.name, summary: decision.summary } if decision.method == PlaybackSession::Method::VideoTranscode
        end
        next if needing.empty?

        rows << { media_file_id: file.id, filename: file.filename, devices: needing, all_devices: needing.size == devices.size,
                  library_id: file.library_id, size: file.size, duration_seconds: file.duration_seconds }
      end
      titles = titles_for(rows.pluck(:media_file_id))
      rows.map { |row| row.merge(title: titles[row[:media_file_id]]) }.sort_by { |row| row[:title].to_s }
    end

    # What each file is a file of. Asked once the files that need converting
    # are known, so a library's worth of titles is never loaded to name a few.
    sig { params(media_file_ids: T::Array[String]).returns(T::Hash[String, T.nilable(String)]) }
    def self.titles_for(media_file_ids)
      media_file_ids.each_slice(1000).each_with_object({}) do |ids, titles|
        Edition.where(media_file_id: ids).includes(playable: :show).each do |edition|
          titles[edition.media_file_id] ||= title_for(edition.playable)
        end
      end
    end

    sig { params(playable: T.untyped).returns(T.nilable(String)) }
    def self.title_for(playable)
      case playable
      when Movie then [ playable.title, playable.year ].compact.join(" ")
      when Episode then "#{playable.show&.title} #{playable.code}"
      when Video, Extra then playable.title
      when LiveStream then playable.name
      end
    end
  end
end

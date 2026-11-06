# typed: strict
# frozen_string_literal: true

module Stations
  # Fills a channel's schedule (PROPOSAL §7.7). Only ever appends after the
  # last airing, so what's fixed stays fixed; `rebuild!` (after an edit)
  # first drops what hasn't started. Deterministic: the same rules, library
  # and history give the same schedule, so a preview is what will air.
  #
  # Walking forward from the last airing's end: the highest layer covering
  # that minute picks the next program by its ordering. A special or an
  # appointment starts on the dot, so what airs before one is chosen to end
  # in time — and when nothing fits, the gap is a slate. A daypart waits for
  # the program before it to finish. Starts snap to the channel's grid. Over
  # every layer, the channel's teams' games (Games), each starting on the
  # dot like an appointment.
  class Scheduler
    extend T::Sig

    # What airs is fixed from here: a program that started stays.
    sig { params(station: Station, now: ActiveSupport::TimeWithZone).returns(Integer) }
    def self.rebuild!(station, now: Time.current)
      drop_future!(station, now)
      extend!(station, now: now)
    end

    # What hasn't started yet, gone: a program that started stays.
    sig { params(station: Station, now: ActiveSupport::TimeWithZone).void }
    def self.drop_future!(station, now)
      Airing.unscoped.where(station_id: station.id).where("starts_at > ?", now).delete_all
    end

    # Airings written.
    sig { params(station: Station, now: ActiveSupport::TimeWithZone, through: T.nilable(ActiveSupport::TimeWithZone)).returns(Integer) }
    def self.extend!(station, now: Time.current, through: nil)
      scheduler = new(station, now: now)
      airings = scheduler.plan(through: through || (now + Station::HORIZON))
      Airing.insert_all!(airings.map(&:attributes).map { |row| row.except("id") }) if airings.any?
      station.update!(scheduled_through: [ scheduler.cursor, station.scheduled_through ].compact.max, last_scheduled_at: now,
        last_error: scheduler.problem)
      airings.size
    end

    sig { returns(ActiveSupport::TimeWithZone) }
    attr_reader :cursor

    # Why nothing could be scheduled, if so.
    sig { returns(T.nilable(String)) }
    attr_reader :problem

    # What happened along the way worth saying in the editor's preview: a
    # show that ran out, or started over.
    Note = Struct.new(:kind, :block_id, :title, :at)

    sig { returns(T::Array[T.untyped]) }
    attr_reader :notes

    # A gap shorter than this stays the slate.
    FILLER_GAP = 20.0

    sig { params(station: Station, now: ActiveSupport::TimeWithZone, zone: T.nilable(ActiveSupport::TimeZone)).void }
    def initialize(station, now: Time.current, zone: nil)
      @station = station
      @now = now
      @zone = T.let(zone || AppSetting.cached.zone, ActiveSupport::TimeZone)
      @blocks = T.let(station.station_blocks.to_a.sort_by { |block| [ -block.layer_enum.rank, block.position ] }, T::Array[StationBlock])
      @pools = T.let({}, T::Hash[String, T::Array[Candidate]])
      @history = T.let(History.new(station, since: now - [ station.no_repeat_days, 1 ].max.days), History)
      last = Airing.unscoped.where(station_id: station.id).order(:starts_at).last
      start = last && last.ends_at > now - 1.hour ? snap(last.ends_at) : grid_floor(now)
      @cursor = T.let(start, ActiveSupport::TimeWithZone)
      @problem = T.let(nil, T.nilable(String))
      @notes = T.let([], T::Array[T.untyped])
      @filler = T.let(Source.filler(station), T::Array[Candidate])
      @chapters = T.let({}, T::Hash[String, T::Array[Float]])
      # A block's pool sorted, and split by series: a pool never changes
      # while a plan is made, and a week's plan picks hundreds of times.
      @sequences = T.let({}, T::Hash[[ String, Symbol ], T::Array[Candidate]])
      @by_series = T.let({}, T::Hash[[ String, Symbol ], T::Hash[String, T::Array[Candidate]]])
      @series_order = T.let({}, T::Hash[String, T::Array[String]])
      @games = T.let([], T::Array[Games::Slot])
      @team_streams = T.let({}, T::Hash[Integer, LiveStream])
    end

    # The airings from the cursor up to `through`, unsaved.
    sig { params(through: ActiveSupport::TimeWithZone).returns(T::Array[Airing]) }
    def plan(through:)
      planned = T.let([], T::Array[Airing])
      # A stream's channel (PROPOSAL §7.8): the stream is what's on.
      return planned if @station.streams?

      @games = games(through)
      if @blocks.empty? && @station.mlb_team_ids.empty?
        @problem = "This channel has no programming yet"
        return planned
      end

      guard = 0
      while @cursor < through && (guard += 1) < 20_000
        game = @games.find { |slot| slot.starts_at <= @cursor && slot.ends_at > @cursor }
        if game
          place_game(game, planned)
          next
        end

        block = active_block(@cursor)
        hard = [ next_hard_start(@cursor), @games.find { |slot| slot.starts_at > @cursor }&.starts_at ].compact.min
        # A special's or appointment's slot is its own: nothing runs past it.
        closes = block && block.layer_enum.hard_start? ? block.closes_after(@cursor, @zone) : nil
        hard = [ hard, closes ].compact.min
        room = hard ? (hard - @cursor).to_f : Float::INFINITY
        choice = block && pick(block, room)
        if choice.nil? && block && !block.base?
          # The block's own mix has nothing that fits: the base fills in.
          base = @blocks.find(&:base?)
          choice = base && pick(base, room)
          block = base if choice
        end
        if choice.nil? || block.nil?
          @problem ||= "Nothing in the library matches #{block ? "“#{block.label}”" : 'this channel'}" if pool_for(block).empty? && (block || @blocks.any?)
          resume = hard && hard <= @cursor + 3.hours ? hard : @cursor + 30.minutes
          fill(@cursor, resume, planned)
          @cursor = resume
          next
        end

        candidate, reason = choice
        ends = @cursor + candidate.duration.seconds
        @history.add(block.id, candidate, @cursor)
        following = snap(ends)
        resume = hard && following > hard && ends <= hard ? hard : following
        place(block, candidate, reason, resume, planned)
        @cursor = resume
      end
      planned
    end

    # What a block can air: its rules applied to the library, once per plan.
    sig { params(block: T.nilable(StationBlock)).returns(T::Array[Candidate]) }
    def pool_for(block)
      return [] if block.nil?

      @pools[block.id] ||= Source.candidates(@station.household_id, block.source)
    end

    private

    # The channel's teams' games through `through`, but none it has aired or
    # is airing: a game cut short when it ended isn't scheduled again.
    sig { params(through: ActiveSupport::TimeWithZone).returns(T::Array[Games::Slot]) }
    def games(through)
      return [] if @station.mlb_team_ids.empty?

      aired = Airing.unscoped.where(station_id: @station.id).where.not(mlb_game_pk: nil).where("ends_at > ?", @now - 1.day)
        .pluck(:mlb_game_pk).to_set
      Games.slots(@station, from: @cursor, to: through, now: @now, zone: @zone).reject { |slot| aired.include?(slot.game_pk) }
    rescue Games::Unavailable, Mlb::Schedule::Error => e
      @problem = e.is_a?(Games::Unavailable) ? e.message : "MLB's schedule couldn't be read, so its games aren't on yet: #{e.message}"
      []
    end

    # A game, from the cursor (later than its slot opens when what came
    # before ran into it) to its slot's end, playing the team's stream.
    sig { params(slot: Games::Slot, planned: T::Array[Airing]).void }
    def place_game(slot, planned)
      stream = @team_streams[slot.team_id] ||= Mlb::TeamStreams.for(@station.household_id, slot.team_id, slot.team_name)
      planned << Airing.new(household_id: @station.household_id, station_id: @station.id, playable_type: "LiveStream",
        playable_id: stream.id, series_key: "mlb:#{slot.team_id}", starts_at: @cursor, ends_at: slot.ends_at,
        reason: "#{slot.team_name} baseball", mlb_game_pk: slot.game_pk, program_title: slot.title,
        program_subtitle: slot.subtitle, created_at: @now)
      # The channel's grid again, unless another game starts first (a
      # doubleheader's second).
      resume = snap(slot.ends_at)
      following = @games.find { |other| other.starts_at >= slot.ends_at }&.starts_at
      resume = following if following && following < resume
      fill(slot.ends_at, resume, planned)
      @cursor = resume
    end

    # One program from the cursor, and filler until `resume`: at its end,
    # or — on a channel that takes breaks — spread into breaks at its
    # chapters, so it airs in parts with a share of the spare time between
    # each and after the last.
    sig do
      params(block: StationBlock, candidate: Candidate, reason: String, resume: ActiveSupport::TimeWithZone, planned: T::Array[Airing]).void
    end
    def place(block, candidate, reason, resume, planned)
      spare = (resume - @cursor).to_f - candidate.duration
      points = @station.breaks && @filler.any? ? break_points(candidate, spare) : []
      share = points.empty? ? 0.0 : spare / (points.size + 1)
      at = T.let(@cursor, ActiveSupport::TimeWithZone)
      from = T.let(0.0, Float)
      (points + [ nil ]).each do |point|
        upto = point || candidate.duration
        ends = at + (upto - from).seconds
        planned << Airing.new(household_id: @station.household_id, station_id: @station.id, station_block_id: block.id,
          playable_type: candidate.playable_type, playable_id: candidate.playable_id, media_file_id: candidate.media_file_id,
          series_key: candidate.series_key, starts_at: at, ends_at: ends, media_start: from, media_end: point, reason: reason,
          created_at: @now)
        break if point.nil?

        fill(ends, ends + share.seconds, planned)
        at = ends + share.seconds
        from = point
      end
      fill(planned.last&.ends_at || @cursor, resume, planned)
    end

    # Where a program breaks (seconds into its file): after a cold open,
    # and at chapters between the first sixth and the last tenth, at least
    # four minutes apart — as many as the spare time allows a minute each
    # (with one left for the end), three at most.
    sig { params(candidate: Candidate, spare: Float).returns(T::Array[Float]) }
    def break_points(candidate, spare)
      allowed = [ (spare / 60).floor - 1, 3 ].min
      return [] if allowed <= 0

      length = candidate.duration
      load_chapters(candidate.media_file_id) unless @chapters.key?(candidate.media_file_id)
      points = T.let([], T::Array[Float])
      T.must(@chapters[candidate.media_file_id]).each do |start|
        next if start < 60 || start > length * 0.9
        next if points.empty? && start < length / 6 && start != T.must(@chapters[candidate.media_file_id]).first
        next if points.any? && start - T.must(points.last) < 240

        points << start
      end
      return points if points.size <= allowed

      # Spread evenly across the program.
      Array.new(allowed) { |index| T.must(points[((index + 1) * points.size / (allowed + 1.0)).floor]) }.uniq
    end

    # Filler from the end of one program to the start of the next, when the
    # channel has some and the gap is worth filling.
    sig { params(from: ActiveSupport::TimeWithZone, to: ActiveSupport::TimeWithZone, planned: T::Array[Airing]).void }
    def fill(from, to, planned)
      return if @filler.empty?

      at = T.let(from, ActiveSupport::TimeWithZone)
      while (room = (to - at).to_f) >= FILLER_GAP
        fits = @filler.select { |candidate| candidate.duration <= room }
        break if fits.empty?

        fresh = fits.reject { |candidate| @history.aired_recently?(candidate.playable_id) }
        fresh = fits if fresh.empty?
        rng = Random.new(Digest::SHA256.hexdigest("#{@station.id}:filler:#{at.to_i}").first(15).to_i(16))
        pick = T.must(fresh.sort_by(&:playable_id)[rng.rand(fresh.size)])
        planned << Airing.new(household_id: @station.household_id, station_id: @station.id, playable_type: pick.playable_type,
          playable_id: pick.playable_id, media_file_id: pick.media_file_id, series_key: pick.series_key, starts_at: at,
          ends_at: at + pick.duration.seconds, reason: "Between programs", filler: true, created_at: @now)
        @history.add("filler", pick, at)
        at += pick.duration.seconds
      end
    end

    sig { params(kind: Symbol, block: StationBlock, title: String).void }
    def note(kind, block, title)
      return if @notes.any? { |note| note.kind == kind && note.block_id == block.id && note.title == title }

      @notes << Note.new(kind, block.id, title, @cursor)
    end

    # The highest layer in charge at this moment.
    sig { params(time: ActiveSupport::TimeWithZone).returns(T.nilable(StationBlock)) }
    def active_block(time)
      local = time.in_time_zone(@zone)
      @blocks.find { |block| block.covers?(local) }
    end

    # The next on-the-dot start after this moment, within a day.
    sig { params(time: ActiveSupport::TimeWithZone).returns(T.nilable(ActiveSupport::TimeWithZone)) }
    def next_hard_start(time)
      @blocks.select { |block| block.layer_enum.hard_start? }
        .filter_map { |block| block.next_start(time + 1.second, @zone, within: 1.day) }.min
    end

    # Where every file in the pools so far could break: its intro's end
    # and its chapters, read for all of them at once rather than a file
    # (and its markers) per program.
    sig { params(wanted: String).void }
    def load_chapters(wanted)
      ids = ([ wanted ] + @pools.values.flatten.map(&:media_file_id) - @chapters.keys).uniq
      intros = T.let({}, T::Hash[String, Float])
      Marker.unscoped.where(media_file_id: ids, kind: Marker::Kind::Intro.serialize).order(:start_seconds)
        .pluck(:media_file_id, :start_seconds).each { |id, start| intros[id] ||= start }
      MediaFile.unscoped.where(id: ids).pluck(:id, :chapters).each do |id, chapters|
        starts = Array(chapters).filter_map { |chapter| chapter["start"].to_f.nonzero? }
        @chapters[id] = ([ intros[id] ].compact.select { |start| start >= 60 } + starts).sort
      end
      ids.each { |id| @chapters[id] ||= [] }
    end

    # The next program from a block, and why, that ends within `room`.
    sig { params(block: StationBlock, room: Float).returns(T.nilable([ Candidate, String ])) }
    def pick(block, room)
      pool = pool_for(block)
      return nil if pool.empty?

      label = block.label
      ordering = block.ordering_enum
      case ordering
      when StationBlock::Ordering::Shuffle
        candidate = shuffled(block, pool, room)
        candidate && [ candidate, "#{label} · shuffled" ]
      when StationBlock::Ordering::Sequential
        candidate = following(block, sequence_of(block, pool, :order), @history.last_in(block.id), room, by: :order)
        candidate && [ candidate, "#{label} · next in order" ]
      when StationBlock::Ordering::Chronological
        candidate = following(block, sequence_of(block, pool, :aired), @history.last_in(block.id), room, by: :aired)
        candidate && [ candidate, "#{label} · in the order they aired" ]
      when StationBlock::Ordering::Rotate
        candidate = rotated(block, pool, room)
        candidate && [ candidate, "#{label} · #{candidate.series_title}, next in rotation" ]
      when StationBlock::Ordering::Marathon
        candidate = marathon(block, pool, room)
        candidate && [ candidate, "#{label} · #{candidate.series_title} marathon" ]
      else T.absurd(ordering)
      end
    end

    sig { params(block: StationBlock, pool: T::Array[Candidate], room: Float).returns(T.nilable(Candidate)) }
    def shuffled(block, pool, room)
      fits = pool.select { |candidate| candidate.duration <= room }
      return nil if fits.empty?

      fresh = fits.reject { |candidate| @history.aired_recently?(candidate.playable_id) }
      # Everything has been on lately: the one least recently aired.
      return fits.min_by { |candidate| @history.last_aired(candidate.playable_id) || @now } if fresh.empty?

      fresh.sort_by(&:playable_id)[random(block).rand(fresh.size)]
    end

    # One show after another in turn, each where it left off.
    sig { params(block: StationBlock, pool: T::Array[Candidate], room: Float).returns(T.nilable(Candidate)) }
    def rotated(block, pool, room)
      series = @series_order[block.id] ||= begin
        titles = pool.group_by(&:series_key).transform_values { |each| each.first&.series_title.to_s }
        titles.keys.sort_by { |key| [ titles.fetch(key), key ] }
      end
      last = @history.last_in(block.id)
      start = last ? (series.index(last.series_key) || -1) + 1 : 0
      series.size.times do |step|
        key = series.fetch((start + step) % series.size)
        candidate = next_of_series(block, pool, key, room)
        return candidate if candidate
      end
      nil
    end

    # A few of one show in a row, then another show chosen at random.
    sig { params(block: StationBlock, pool: T::Array[Candidate], room: Float).returns(T.nilable(Candidate)) }
    def marathon(block, pool, room)
      last = @history.last_in(block.id)
      if last && @history.run_length(block.id) < block.marathon_length
        candidate = next_of_series(block, pool, last.series_key, room)
        return candidate if candidate
      end
      series = pool.map(&:series_key).uniq.sort
      series -= [ last.series_key ] if last && series.size > 1
      rng = random(block)
      series.shuffle(random: rng).each do |key|
        other = next_of_series(block, pool, key, room)
        return other if other
      end
      nil
    end

    sig do
      params(block: StationBlock, pool: T::Array[Candidate], key: String, room: Float).returns(T.nilable(Candidate))
    end
    def next_of_series(block, pool, key, room)
      by = key == "movies" ? :aired : :order
      list = (@by_series[[ block.id, by ]] ||= sequence_of(block, pool, by).group_by(&:series_key)).fetch(key, [])
      following(block, list, @history.last_of(block.id, key), room, by: by)
    end

    # What comes after `last` in `list` (the first when there's no last),
    # looping when the block does — `list` sorted `by` that key, so a last
    # no longer in it resumes at its place in the same order. Nil when it
    # doesn't fit: an episode in order is never skipped for being too long.
    sig do
      params(block: StationBlock, list: T::Array[Candidate], last: T.nilable(Candidate), room: Float, by: Symbol)
        .returns(T.nilable(Candidate))
    end
    def following(block, list, last, room, by:)
      return nil if list.empty?

      index =
        if last.nil? then 0
        else
          position = list.index { |candidate| candidate.playable_id == last.playable_id }
          position ? position + 1 : (list.index { |candidate| (sort_key(candidate, by) <=> sort_key(last, by)).to_i.positive? } || list.size)
        end
      if index >= list.size
        title = list.last&.series_title.to_s
        note(block.loops ? :starts_over : :runs_out, block, title)
        return nil unless block.loops

        index = 0
      end
      candidate = list.fetch(index)
      candidate.duration <= room ? candidate : nil
    end

    sig { params(block: StationBlock, pool: T::Array[Candidate], by: Symbol).returns(T::Array[Candidate]) }
    def sequence_of(block, pool, by) = @sequences[[ block.id, by ]] ||= pool.sort_by { |candidate| sort_key(candidate, by) }

    sig { params(candidate: Candidate, by: Symbol).returns(T::Array[T.untyped]) }
    def sort_key(candidate, by)
      aired = candidate.aired_on&.jd || Float::INFINITY
      if by == :aired
        [ aired, candidate.series_title, candidate.season, candidate.episode, candidate.playable_id ]
      else
        [ candidate.series_title, candidate.series_key, candidate.season, candidate.episode, aired, candidate.playable_id ]
      end
    end

    # Seeded by the channel, the block and the moment: the same every time.
    sig { params(block: StationBlock).returns(Random) }
    def random(block)
      Random.new(Digest::SHA256.hexdigest("#{@station.id}:#{block.id}:#{@cursor.to_i}").first(15).to_i(16))
    end

    # The next start on the channel's grid at or after this moment.
    sig { params(time: ActiveSupport::TimeWithZone).returns(ActiveSupport::TimeWithZone) }
    def snap(time)
      minutes = @station.snap_minutes
      # Back to back: the next starts the moment this one ends, with no gap
      # to show a slate in.
      return time if minutes.zero?

      floor = grid_floor(time, minutes)
      floor == time ? floor : floor + minutes.minutes
    end

    # The start of the grid slot this moment is in (half hours by default),
    # so a new channel already has something on.
    sig { params(time: ActiveSupport::TimeWithZone, minutes: Integer).returns(ActiveSupport::TimeWithZone) }
    def grid_floor(time, minutes = @station.snap_minutes.nonzero? || 30)
      local = time.in_time_zone(@zone)
      midnight = local.beginning_of_day
      slots = ((local - midnight) / (minutes * 60)).floor
      midnight + (slots * minutes).minutes
    end
  end
end

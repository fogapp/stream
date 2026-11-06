# typed: strict
# frozen_string_literal: true

module Stations
  # What a channel's programming would air over the next week, before it's
  # saved (PROPOSAL §7.7): the real scheduler run inside a transaction that
  # is rolled back, so the preview is exactly what saving would do — and
  # what's worth knowing about it, in plain words.
  module Preview
    extend T::Sig

    DAYS = 7

    sig do
      params(station: Station, blocks: T::Array[T::Hash[Symbol, T.untyped]], now: ActiveSupport::TimeWithZone)
        .returns(T::Hash[Symbol, T.untyped])
    end
    def self.run(station, blocks, now: Time.current)
      result = T.let({ airings: [], warnings: [] }, T::Hash[Symbol, T.untyped])
      # A channel not made yet is planned under a number no channel has. Under
      # its own, the preview's uncommitted row would hold that number in the
      # unique index while the week is planned (seconds), and saving the
      # channel meanwhile would wait for it — or the preview would fail with
      # a duplicate once the save got there first.
      station.number = unused_number(station.household_id) if station.new_record?
      Station.transaction do
        station.save!
        made = station.replace_blocks!(blocks)
        station.reload
        Scheduler.drop_future!(station, now)
        scheduler = Scheduler.new(station, now: now)
        planned = scheduler.plan(through: now + DAYS.days)
        kept = Airing.unscoped.where(station_id: station.id).where("ends_at > ?", now).order(:starts_at).to_a
        airings = kept + planned
        # Never saved: ids only so the page can tell them apart.
        planned.each { |airing| airing.id = SecureRandom.uuid }
        ActiveRecord::Associations::Preloader.new(records: airings, associations: :playable).call
        blocks_by_id = made.each_with_index.to_h { |block, index| [ block.id.to_s, index ] }
        by_id = airings.index_by(&:id)
        result = {
          airings: StationSerializer.airings_json(airings).map do |json|
            json.merge(block_index: blocks_by_id[by_id[json[:id]]&.station_block_id.to_s])
          end,
          warnings: warnings(station, made, airings, scheduler, now)
        }
        raise ActiveRecord::Rollback
      end
      result
    end

    sig { params(household_id: String).returns(String) }
    def self.unused_number(household_id)
      taken = Station.unscoped.where(household_id: household_id).pluck(:number).to_set
      candidate = "9999.99"
      10.times do
        candidate = "#{SecureRandom.random_number(9000) + 1000}.#{SecureRandom.random_number(90) + 10}"
        break unless taken.include?(candidate)
      end
      candidate
    end
    private_class_method :unused_number

    sig do
      params(station: Station, blocks: T::Array[StationBlock], airings: T::Array[Airing], scheduler: Scheduler,
        now: ActiveSupport::TimeWithZone).returns(T::Array[T::Hash[Symbol, String]])
    end
    def self.warnings(station, blocks, airings, scheduler, now)
      said = T.let([], T::Array[T::Hash[Symbol, String]])
      zone = AppSetting.cached.zone
      blocks.each do |block|
        pool = scheduler.pool_for(block)
        if pool.empty?
          said << { tone: "danger", text: "Nothing in the library matches “#{block.label}” — it airs nothing, and what's underneath fills in." }
          next
        end
        next unless block.ordering_enum == StationBlock::Ordering::Shuffle

        aired = airings.select { |airing| airing.station_block_id == block.id }.sum(0.0, &:duration)
        library = pool.sum(0.0, &:duration)
        next unless aired > library

        said << { tone: "warning", text: "“#{block.label}” has #{hours(library)} of programs for #{hours(aired)} a week, so they come round again within the week." }
      end
      scheduler.notes.each do |note|
        block = blocks.find { |candidate| candidate.id == note.block_id }
        when_said = note.at.in_time_zone(zone).strftime("%a %-d %b")
        said << if note.kind == :runs_out
          { tone: "warning", text: "#{note.title} runs out in “#{block&.label}” on #{when_said}; after that the slot goes to what's underneath." }
        else
          { tone: "info", text: "#{note.title} starts over from the beginning in “#{block&.label}” on #{when_said}." }
        end
      end
      said.concat(hidden_from(station, airings))
      slate = slate_seconds(airings.reject(&:filler), now)
      if station.filler_enum == Station::Filler::Slate && slate > 3600
        said << { tone: "info", text: "About #{hours(slate)} a week is the slate between programs — filler, or starting programs back to back, would fill it." }
      end
      said
    end
    private_class_method :warnings

    # Restricted profiles that won't see the channel, and why — asked of
    # Viewing::Access as each of them, so it's the guide's own answer.
    # A curated profile sees only what's tagged for it, so it isn't news.
    sig { params(station: Station, airings: T::Array[Airing]).returns(T::Array[T::Hash[Symbol, String]]) }
    def self.hidden_from(station, airings)
      titles = airings.filter_map(&:playable).uniq
      return [] if titles.empty?

      ActiveRecord::Associations::Preloader.new(records: titles.grep(Episode), associations: :show).call
      ActiveRecord::Associations::Preloader.new(records: titles.grep(Extra), associations: :owner).call
      shut = T.let([], T::Array[Profile])
      barred = T.let([], T::Array[T.untyped])
      Profile.unscoped.where(household_id: station.household_id).order(:position).reject(&:curated).each do |profile|
        seen = Current.set(profile: profile) { Viewing::Access.permitted(titles) }
        next if seen.size == titles.size

        shut << profile
        barred.concat(titles - seen)
      end
      return [] if shut.empty?

      [ { tone: "info", text: "#{shut.map(&:name).to_sentence} won't see this channel: it airs #{barred_kind(barred.uniq)}." } ]
    end
    private_class_method :hidden_from

    # The highest rating among what's barred, or what else bars it.
    sig { params(titles: T::Array[T.untyped]).returns(String) }
    def self.barred_kind(titles)
      rated = titles.map { |title| rated_title(title) }.compact.uniq.select { |title| title.respond_to?(:rating_age) }
      highest = rated.reject { |title| title.rating_age.nil? }.max_by(&:rating_age)
      return highest.content_rating.to_s if highest&.content_rating.present?
      return "unrated titles" if rated.any? { |title| title.rating_age.nil? }
      return "YouTube channels not tagged for them" if titles.any?(Video)

      "titles hidden from them"
    end
    private_class_method :barred_kind

    # The title whose rating this answers to: an episode's show, an extra's
    # film or show.
    sig { params(title: T.untyped).returns(T.untyped) }
    def self.rated_title(title)
      case title
      when Episode then title.show
      when Extra then title.owner.is_a?(Season) ? title.owner.show : title.owner
      else title
      end
    end
    private_class_method :rated_title

    sig { params(airings: T::Array[Airing], now: ActiveSupport::TimeWithZone).returns(Float) }
    def self.slate_seconds(airings, now)
      sorted = airings.sort_by(&:starts_at)
      sorted.each_cons(2).sum(0.0) do |pair|
        before, after = pair
        next 0.0 if before.nil? || after.nil?

        [ (after.starts_at - [ before.ends_at, now ].max).to_f, 0.0 ].max
      end
    end
    private_class_method :slate_seconds

    sig { params(seconds: Float).returns(String) }
    def self.hours(seconds)
      hours = seconds / 3600
      return "#{hours.round} hour#{'s' unless hours.round == 1}" if hours >= 1

      minutes = [ (seconds / 60).round, 1 ].max
      "#{minutes} minute#{'s' unless minutes == 1}"
    end
    private_class_method :hours
  end
end

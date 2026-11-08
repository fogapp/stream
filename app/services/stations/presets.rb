# typed: strict
# frozen_string_literal: true

module Stations
  # Ready-made channels (PROPOSAL §7.7), written as ordinary blocks the
  # editor shows and anyone can change — never hidden logic. Built from
  # what's in the library: a network's own shows, its best in primetime.
  module Presets
    extend T::Sig

    class Kind < T::Enum
      include ApplicationEnum
      enums do
        Network = new("network")
        Kids = new("kids")
        Sitcoms = new("sitcoms")
        Decade = new("decade")
        Movies = new("movies")
        OneShow = new("one_show")
        Holiday = new("holiday")
        Youtube = new("youtube")
      end
    end

    # How each network programs: a broadcaster's week, a premium channel's
    # films and Sunday originals, a kids' channel, or cable's marathons.
    BROADCAST = T.let(%w[NBC CBS ABC FOX Fox The\ CW PBS UPN The\ WB ITV BBC\ One BBC\ Two Channel\ 4].freeze, T::Array[String])
    PREMIUM = T.let(%w[HBO Showtime Starz Cinemax Epix MGM+ Max HBO\ Max].freeze, T::Array[String])
    KIDS = T.let(%w[Nickelodeon Disney\ Channel Cartoon\ Network Disney\ Junior Nick\ Jr. PBS\ Kids CBBC CBeebies Disney\ XD].freeze, T::Array[String])
    # The numbers they had on the dial, where they're free.
    NUMBERS = T.let({
      "NBC" => "4", "CBS" => "2", "ABC" => "7", "FOX" => "5", "Fox" => "5", "PBS" => "13", "The CW" => "11", "HBO" => "501",
      "Showtime" => "545", "Cinemax" => "515", "Starz" => "525", "AMC" => "254", "FX" => "248", "USA Network" => "242",
      "Comedy Central" => "249", "Nickelodeon" => "299", "Cartoon Network" => "296", "Disney Channel" => "290", "TNT" => "245",
      "TBS" => "247", "Syfy" => "244", "BBC One" => "101", "BBC Two" => "102", "ITV" => "103", "Channel 4" => "104"
    }.freeze, T::Hash[String, String])

    COMEDY = T.let(%w[Comedy].freeze, T::Array[String])
    DRAMA = T.let([ "Drama", "Crime", "Sci-Fi & Fantasy", "Action & Adventure", "Mystery", "War & Politics", "Western" ].freeze, T::Array[String])
    CARTOONS = T.let(%w[Animation Kids Family].freeze, T::Array[String])
    HOLIDAYS = T.let({
      "christmas" => { name: "Christmas", keywords: %w[christmas holiday santa\ claus christmas\ party christmas\ eve], from: "12-01", to: "12-26" },
      "halloween" => { name: "Halloween", keywords: %w[halloween trick\ or\ treating haunted\ house], from: "10-01", to: "10-31" },
      "thanksgiving" => { name: "Thanksgiving", keywords: %w[thanksgiving], from: "11-15", to: "11-30" }
    }.freeze, T::Hash[String, T::Hash[Symbol, T.untyped]])

    WEEKDAYS = 0b0011111
    SATURDAY = 0b0100000
    SUNDAY = 0b1000000

    sig { params(household_id: String, kind: Kind, value: T.nilable(String)).returns(T::Hash[Symbol, T.untyped]) }
    def self.build(household_id, kind, value)
      draft =
        case kind
        when Kind::Network then network(household_id, value.to_s)
        when Kind::Kids then kids
        when Kind::Sitcoms then sitcoms
        when Kind::Decade then decade(value.to_i)
        when Kind::Movies then movies(value.to_s)
        when Kind::OneShow then one_show(household_id, value.to_s)
        when Kind::Holiday then holiday(value.to_s)
        when Kind::Youtube then youtube
        else T.absurd(kind)
        end
      { snap_minutes: 30, no_repeat_days: 3, filler: "slate", filler_channel_ids: [], call_sign: nil }
        .merge(draft)
        .merge(number: free_number(household_id, NUMBERS[value.to_s] || draft[:number]))
    end

    # A broadcaster's week from its own shows: reruns in the morning, its
    # best comedies at 8 and dramas from 9 on weeknights (each show in
    # order, week after week), comedies late, cartoons on Saturday morning.
    sig { params(household_id: String, name: String).returns(T::Hash[Symbol, T.untyped]) }
    def self.network(household_id, name)
      shows = Show.unscoped.where(household_id: household_id).where(Show.overlap(:networks, [ name ])).order(vote_average: :desc)
      base = { networks: [ name ], kinds: %w[episode] }
      comedies = pick(shows, COMEDY)
      dramas = pick(shows, DRAMA)
      blocks = T.let([ block("base", source: base, ordering: "rotate") ], T::Array[T::Hash[Symbol, T.untyped]])

      if PREMIUM.include?(name)
        # Films on the hour, its own series on Sunday nights.
        blocks = [ block("base", source: { kinds: %w[movie], min_rating: 6.0, studios: studios_like(household_id, name) }.compact, ordering: "shuffle") ]
        blocks[0][:source].delete(:studios) if blocks[0][:source][:studios].blank?
        (dramas + comedies).first(2).each_with_index do |show, index|
          blocks << appointment(show, SUNDAY, (21 + index) * 60, 60)
        end
        return { name: name, call_sign: sign(name), snap_minutes: 60, blocks: blocks, description: "Films on the hour, and #{name}'s own series on Sunday nights." }
      end

      if KIDS.include?(name)
        blocks << block("daypart", name: "Saturday morning", days: SATURDAY, start: 7 * 60, finish: 12 * 60, source: base, ordering: "marathon")
        return { name: name, call_sign: sign(name), blocks: blocks, description: "#{name}'s shows in rotation, with a Saturday morning marathon." }
      end

      blocks << block("daypart", name: "Morning reruns", days: WEEKDAYS, start: 6 * 60, finish: 9 * 60,
        source: base.merge(genres: COMEDY), ordering: "rotate")
      if BROADCAST.include?(name)
        # Primetime: Monday to Friday, a different night's line-up each.
        5.times do |day|
          comedy = comedies[day * 2]
          second = comedies[(day * 2) + 1]
          drama = dramas[day * 2]
          late = dramas[(day * 2) + 1]
          blocks << appointment(comedy, 1 << day, 20 * 60, 30) if comedy
          blocks << appointment(second, 1 << day, (20 * 60) + 30, 30) if second
          blocks << appointment(drama, 1 << day, 21 * 60, 60) if drama
          blocks << appointment(late, 1 << day, 22 * 60, 60) if late
        end
        blocks << block("daypart", name: "Late night", days: StationBlock::EVERY_DAY, start: (23 * 60) + 30, finish: 2 * 60,
          source: base.merge(genres: COMEDY), ordering: "shuffle")
        cartoons = shows.where(Show.overlap(:genres, CARTOONS)).exists?
        if cartoons
          blocks << block("daypart", name: "Saturday morning", days: SATURDAY, start: 8 * 60, finish: 11 * 60,
            source: base.merge(genres: CARTOONS), ordering: "marathon")
        end
        description = "#{name}'s week: reruns in the morning, its best at 8, 9 and 10 on weeknights, comedy late."
      else
        blocks << block("daypart", name: "Primetime", days: StationBlock::EVERY_DAY, start: 20 * 60, finish: 23 * 60,
          source: base.merge(genres: DRAMA), ordering: "marathon")
        description = "#{name}'s shows in rotation, with dramas back to back in primetime."
      end
      { name: name, call_sign: sign(name), blocks: blocks, description: description }
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def self.kids
      base = { genres: CARTOONS, max_rating_age: 7, allow_unrated: false }
      {
        number: "30", name: "Kids", call_sign: "KIDS", description: "Cartoons and family shows for little ones, films after school, and Saturday morning cartoons.",
        blocks: [
          block("base", source: base.merge(kinds: %w[episode]), ordering: "rotate"),
          block("daypart", name: "Saturday morning cartoons", days: SATURDAY, start: 7 * 60, finish: 12 * 60,
            source: base.merge(kinds: %w[episode], genres: %w[Animation]), ordering: "marathon"),
          block("daypart", name: "Family film", days: StationBlock::EVERY_DAY, start: 17 * 60, finish: 19 * 60,
            source: base.merge(kinds: %w[movie], max_rating_age: 10), ordering: "shuffle")
        ]
      }
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def self.sitcoms
      {
        number: "40", name: "Sitcoms", call_sign: "NITE", description: "Classic comedies all day, and syndication-style rotation from 8pm.",
        blocks: [
          block("base", source: { kinds: %w[episode], genres: COMEDY }, ordering: "shuffle"),
          block("daypart", name: "At night", days: StationBlock::EVERY_DAY, start: 20 * 60, finish: 2 * 60,
            source: { kinds: %w[episode], genres: COMEDY }, ordering: "rotate")
        ]
      }
    end

    # The YouTube videos nobody has watched yet, shuffled across channels and
    # back to back: what's seen drops out from the next night's schedule.
    sig { returns(T::Hash[Symbol, T.untyped]) }
    def self.youtube
      {
        number: "60", name: "YouTube", call_sign: "TUBE", snap_minutes: 0,
        description: "The YouTube videos nobody has watched yet, shuffled across channels, one after another.",
        blocks: [ block("base", source: { kinds: %w[video], unwatched: true }, ordering: "shuffle") ]
      }
    end

    sig { params(start: Integer).returns(T::Hash[Symbol, T.untyped]) }
    def self.decade(start)
      start = (start / 10) * 10
      years = { year_from: start, year_to: start + 9 }
      {
        number: start.to_s.last(2), name: start >= 2000 ? "The #{start}s" : "The #{start.to_s.last(2)}s", call_sign: nil,
        description: "Shows that aired in the #{start}s in rotation, and a film of the decade every night at 8.",
        blocks: [
          block("base", source: years.merge(kinds: %w[episode]), ordering: "rotate"),
          block("daypart", name: "Movie of the night", days: StationBlock::EVERY_DAY, start: 20 * 60, finish: 22 * 60,
            source: years.merge(kinds: %w[movie]), ordering: "shuffle")
        ]
      }
    end

    sig { params(genre: String).returns(T::Hash[Symbol, T.untyped]) }
    def self.movies(genre)
      films = T.let({ kinds: %w[movie] }, T::Hash[Symbol, T.untyped])
      films[:genres] = [ genre ] if genre.present?
      {
        number: "60", name: genre.present? ? "#{genre} movies" : "Movies", call_sign: nil, snap_minutes: 30,
        description: "#{genre.presence || 'Films'} back to back, on the half hour, the best-rated in primetime.",
        blocks: [
          block("base", source: films, ordering: "shuffle"),
          block("daypart", name: "Primetime", days: StationBlock::EVERY_DAY, start: 20 * 60, finish: 23 * 60,
            source: films.merge(min_rating: 7.0), ordering: "shuffle")
        ]
      }
    end

    sig { params(household_id: String, show_id: String).returns(T::Hash[Symbol, T.untyped]) }
    def self.one_show(household_id, show_id)
      show = Show.unscoped.find_by(household_id: household_id, id: show_id)
      name = show&.title || "One show"
      { number: "70", name: name, call_sign: nil, snap_minutes: 0, description: "#{name}, all the time, in order, from the first episode.",
        blocks: [ block("base", source: { kinds: %w[episode], show_ids: [ show_id ] }, ordering: "sequential") ] }
    end

    sig { params(key: String).returns(T::Hash[Symbol, T.untyped]) }
    def self.holiday(key)
      holiday = HOLIDAYS.fetch(key) { HOLIDAYS.fetch("christmas") }
      year = Time.current.year
      from = Date.parse("#{year}-#{holiday[:from]}")
      to = Date.parse("#{year}-#{holiday[:to]}")
      from, to = [ from, to ].map { |date| date.next_year } if to < Time.current.to_date
      {
        number: "80", name: holiday[:name], call_sign: nil,
        description: "#{holiday[:name]} episodes and films, all day, every day from #{from.strftime('%b %-d')} to #{to.strftime('%b %-d')}; the rest of the year, the library's best.",
        blocks: [
          block("base", source: { min_rating: 7.0 }, ordering: "shuffle"),
          block("special", name: holiday[:name], days: StationBlock::EVERY_DAY, start: 0, finish: 1440, starts_on: from.iso8601, ends_on: to.iso8601,
            source: { keywords: holiday[:keywords] }, ordering: "shuffle")
        ]
      }
    end

    sig do
      params(layer: String, name: T.nilable(String), days: Integer, start: T.nilable(Integer), finish: T.nilable(Integer),
        starts_on: T.nilable(String), ends_on: T.nilable(String), source: T::Hash[Symbol, T.untyped], ordering: String)
        .returns(T::Hash[Symbol, T.untyped])
    end
    def self.block(layer, name: nil, days: StationBlock::EVERY_DAY, start: nil, finish: nil, starts_on: nil, ends_on: nil, source: {},
      ordering: "shuffle")
      { layer: layer, name: name, days: days, start_minute: start, end_minute: finish, starts_on: starts_on, ends_on: ends_on,
        source: source, ordering: ordering, marathon_length: 3, loops: true }
    end
    private_class_method :block

    sig { params(show: Show, days: Integer, start: Integer, minutes: Integer).returns(T::Hash[Symbol, T.untyped]) }
    def self.appointment(show, days, start, minutes)
      block("appointment", name: show.title, days: days, start: start, finish: (start + minutes) % 1440,
        source: { kinds: %w[episode], show_ids: [ show.id ] }, ordering: "sequential")
    end
    private_class_method :appointment

    # A network's best-rated shows of these genres, with enough episodes to
    # hold a weekly slot.
    sig { params(shows: T.untyped, genres: T::Array[String]).returns(T::Array[Show]) }
    def self.pick(shows, genres)
      readable = Viewing::Catalog.readable_editions.where(playable_type: "Episode").select(:playable_id)
      matching = shows.where(Show.overlap(:genres, genres))
      # Counted by the database, and only for these shows.
      enough = Episode.where(id: readable, show_id: matching.reorder(nil).select(:id)).group(:show_id).having("COUNT(*) >= 4").select(:show_id)
      matching.where(id: enough).to_a
    end
    private_class_method :pick

    sig { params(household_id: String, name: String).returns(T::Array[String]) }
    def self.studios_like(household_id, name)
      Movie.unscoped.where(household_id: household_id).pluck(Arel.sql("DISTINCT unnest(studios)")).select { |studio| studio.to_s.start_with?(name) }
    end
    private_class_method :studios_like

    sig { params(name: String).returns(String) }
    def self.sign(name) = name.gsub(/[^A-Za-z0-9]/, "").upcase.first(5)
    private_class_method :sign

    # The wanted number if free, else the next free whole number after it.
    sig { params(household_id: String, wanted: T.untyped).returns(String) }
    def self.free_number(household_id, wanted)
      taken = Station.unscoped.where(household_id: household_id).pluck(:number).to_set
      number = wanted.to_s.presence || "2"
      return number unless taken.include?(number)

      candidate = number.to_i
      candidate += 1 while taken.include?(candidate.to_s)
      candidate.to_s
    end
    private_class_method :free_number
  end
end

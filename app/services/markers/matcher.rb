# typed: strict
# frozen_string_literal: true

module Markers
  # Finds the stretch of sound two episodes share (PROPOSAL §5.5): the theme
  # tune at the start, the credits music at the end. The approach is
  # Jellyfin's intro-skipper's: Chromaprint fingerprints, an inverted index
  # of exact matches to find how far one episode is shifted against the
  # other, then the longest run of near-identical points at that shift.
  module Matcher
    extend T::Sig

    # One Chromaprint point covers 4096/3 samples at 11,025 Hz.
    SECONDS_PER_POINT = T.let((4096.0 / 3) / 11_025, Float)
    # Points differing in at most this many of their 32 bits count as the
    # same sound (intro-skipper's value).
    MAX_BIT_DIFFERENCE = 6
    # A run may bridge this much mismatch (a sound effect over the theme).
    MAX_GAP_SECONDS = 3.5
    MIN_SECONDS = 15.0
    CANDIDATE_SHIFTS = 5

    POPCOUNT = T.let(Array.new(1 << 16) { |value| value.to_s(2).count("1") }.freeze, T::Array[Integer])

    class Span < T::Struct
      const :start, Float
      const :finish, Float

      extend T::Sig

      sig { returns(Float) }
      def duration = finish - start
    end

    class Match < T::Struct
      const :a, Span
      const :b, Span
      # Share of points in the run that matched.
      const :confidence, Float
    end

    # The longest shared stretch of at least `min` and at most `max`
    # seconds, as spans in each fingerprint's own time (seconds from its
    # start), or nil.
    sig do
      params(a: T::Array[Integer], b: T::Array[Integer], min: Float, max: Float).returns(T.nilable(Match))
    end
    def self.best(a, b, min: MIN_SECONDS, max: Float::INFINITY)
      all(a, b, min: min, max: max).max_by { |match| match.a.duration }
    end

    # Every shared stretch within the length limits, ordered by where it
    # starts in `a`. An episode's theme and its credits can sit at the same
    # offset against a neighbour, so one shift can hold both.
    # A recap is many short clips, each at its own shift: `shifts` looks
    # at more of them.
    sig do
      params(a: T::Array[Integer], b: T::Array[Integer], min: Float, max: Float, shifts: Integer).returns(T::Array[Match])
    end
    def self.all(a, b, min: MIN_SECONDS, max: Float::INFINITY, shifts: CANDIDATE_SHIFTS)
      candidate_shifts(a, b, shifts).flat_map { |shift| runs(a, b, shift) }
        .select { |match| match.a.duration.between?(min, max) }
        .uniq { |match| (match.a.start / 2).round }
        .sort_by { |match| match.a.start }
    end

    # Offsets (a index − b index) where exact matches cluster, most first.
    sig { params(a: T::Array[Integer], b: T::Array[Integer], count: Integer).returns(T::Array[Integer]) }
    def self.candidate_shifts(a, b, count = CANDIDATE_SHIFTS)
      positions = T.let({}, T::Hash[Integer, T::Array[Integer]])
      b.each_with_index { |value, index| (positions[value] ||= []) << index }
      shifts = T.let(Hash.new(0), T::Hash[Integer, Integer])
      a.each_with_index do |value, index|
        Array(positions[value]).each { |other| shifts[index - other] = shifts.fetch(index - other, 0) + 1 }
      end
      shifts.select { |_, hits| hits >= 3 }.sort_by { |_, hits| -hits }.first(count).map(&:first)
    end

    # Half a window each side: ~1 s. A point is part of the shared stretch
    # when at least half of its window matches — so chance matches scattered
    # through different audio can't chain onto the real one.
    WINDOW = 8
    DENSITY = 0.5

    sig { params(a: T::Array[Integer], b: T::Array[Integer], shift: Integer).returns(T::Array[Match]) }
    def self.runs(a, b, shift)
      first = [ shift, 0 ].max
      last = [ a.size, b.size + shift ].min - 1
      return [] if last <= first

      matches = (first..last).map { |index| difference(T.must(a[index]), T.must(b[index - shift])) <= MAX_BIT_DIFFERENCE }
      prefix = T.let([ 0 ], T::Array[Integer])
      matches.each { |hit| prefix << (prefix.fetch(-1) + (hit ? 1 : 0)) }
      dense = matches.each_index.map do |i|
        from = [ i - WINDOW, 0 ].max
        to = [ i + WINDOW, matches.size - 1 ].min
        (T.must(prefix[to + 1]) - T.must(prefix[from])).to_f / (to - from + 1) >= DENSITY
      end

      gap = (MAX_GAP_SECONDS / SECONDS_PER_POINT).round
      regions = T.let([], T::Array[[ Integer, Integer ]])
      dense.each_with_index do |inside, i|
        next unless inside

        current = regions.last
        if current && i - current[1] <= gap
          current[1] = i
        else
          regions << [ i, i ]
        end
      end

      regions.filter_map do |from, to|
        # Trim to the first and last points that actually matched.
        from += 1 while from < to && !matches[from]
        to -= 1 while to > from && !matches[to]
        next nil if to <= from

        hits = T.must(prefix[to + 1]) - T.must(prefix[from])
        span = ->(x, y) { Span.new(start: x * SECONDS_PER_POINT, finish: (y + 1) * SECONDS_PER_POINT) }
        Match.new(a: span.call(first + from, first + to), b: span.call(first + from - shift, first + to - shift),
          confidence: hits.to_f / (to - from + 1))
      end
    end

    sig { params(x: Integer, y: Integer).returns(Integer) }
    def self.difference(x, y)
      bits = (x ^ y) & 0xFFFF_FFFF
      T.must(POPCOUNT[bits & 0xFFFF]) + T.must(POPCOUNT[bits >> 16])
    end
  end
end

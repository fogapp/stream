# typed: strict
# frozen_string_literal: true

# One layer of a channel's programming (PROPOSAL §7.7). For any minute the
# highest layer whose window covers it decides what airs: a special (dates)
# over an appointment (a show at a fixed time) over a daypart (a stretch of
# the day) over the base (everything else). Specials and appointments start
# on the dot — what comes before them is chosen to end in time; a daypart
# waits for whatever is airing to finish.
class StationBlock < ApplicationRecord
  extend T::Sig

  class Layer < T::Enum
    include ApplicationEnum
    enums do
      Base = new("base")
      Daypart = new("daypart")
      Appointment = new("appointment")
      Special = new("special")
    end

    sig { returns(Integer) }
    def rank
      case self
      when Base then 0
      when Daypart then 1
      when Appointment then 2
      when Special then 3
      else T.absurd(self)
      end
    end

    # Starts on the dot, rather than when the program before it ends.
    sig { returns(T::Boolean) }
    def hard_start? = self == Appointment || self == Special
  end

  class Ordering < T::Enum
    include ApplicationEnum
    enums do
      # Anything in the mix, not repeated within the channel's window.
      Shuffle = new("shuffle")
      # One show (or list) straight through: S1E1, S1E2…
      Sequential = new("sequential")
      # Syndication: each show in turn, each picking up where it left off.
      Rotate = new("rotate")
      # A few episodes of one show in a row, then another show.
      Marathon = new("marathon")
      # Everything by original air date, across shows.
      Chronological = new("chronological")
    end
  end

  # Monday first, as the schedule editor shows them.
  DAYS = T.let(%w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday].freeze, T::Array[String])
  EVERY_DAY = 127

  belongs_to :station, inverse_of: :station_blocks
  has_many :airings, dependent: :nullify

  attribute :layer, Layer
  attribute :ordering, Ordering

  validates :name, length: { maximum: 80 }
  validates :days, numericality: { only_integer: true, in: 1..EVERY_DAY }
  validates :marathon_length, numericality: { only_integer: true, in: 1..50 }
  validates :start_minute, :end_minute, numericality: { only_integer: true, in: 0..1440 }, allow_nil: true
  validate :windowed

  sig { returns(T::Boolean) }
  def base? = layer_enum == Layer::Base

  # Whether this block is in charge at a local time (its window covers it,
  # on one of its days, inside its dates). A window may run past midnight;
  # its day is the day it starts.
  sig { params(local: ActiveSupport::TimeWithZone).returns(T::Boolean) }
  def covers?(local)
    return true if base?

    minute = T.let((local.hour * 60) + local.min, Integer)
    start = start_minute.to_i
    finish = end_minute.to_i
    today = on?(local.to_date)
    return today && minute >= start && minute < finish if start < finish

    (today && minute >= start) || (minute < finish && on?(local.to_date.prev_day))
  end

  # The next moment at or after `after` that this block's window opens, if
  # within `within`.
  sig do
    params(after: ActiveSupport::TimeWithZone, zone: ActiveSupport::TimeZone, within: ActiveSupport::Duration)
      .returns(T.nilable(ActiveSupport::TimeWithZone))
  end
  def next_start(after, zone, within: 8.days)
    return nil if base?

    local = after.in_time_zone(zone)
    date = local.to_date
    limit = after + within
    (0..8).each do |offset|
      day = date + offset
      next unless on?(day)

      opens = at_minute(zone, day, start_minute.to_i)
      return nil if opens > limit
      return opens if opens >= after
    end
    nil
  end

  # When the window covering this moment closes (nil for the base).
  sig { params(time: ActiveSupport::TimeWithZone, zone: ActiveSupport::TimeZone).returns(T.nilable(ActiveSupport::TimeWithZone)) }
  def closes_after(time, zone)
    return nil if base?

    local = time.in_time_zone(zone)
    minute = (local.hour * 60) + local.min
    opened = start_minute.to_i < end_minute.to_i || minute >= start_minute.to_i ? local.to_date : local.to_date.prev_day
    closes_on = start_minute.to_i < end_minute.to_i ? opened : opened.next_day
    at_minute(zone, closes_on, end_minute.to_i)
  end

  sig { params(date: Date).returns(T::Boolean) }
  def on?(date)
    return false if starts_on && date < T.must(starts_on)
    return false if ends_on && date > T.must(ends_on)

    days.anybits?(1 << ((date.wday + 6) % 7))
  end

  # What a guide or reason says about this block.
  sig { returns(String) }
  def label
    return name.to_s if name.present?

    layer = layer_enum
    case layer
    when Layer::Base then "The channel's mix"
    when Layer::Daypart then "#{clock(start_minute.to_i)}–#{clock(end_minute.to_i)}"
    when Layer::Appointment then "#{day_names} at #{clock(start_minute.to_i)}"
    when Layer::Special then "Special"
    else T.absurd(layer)
    end
  end

  private

  # A wall-clock minute of a local day (1440 is the next midnight). Built from
  # the clock rather than midnight plus elapsed minutes, so a 20:00 block
  # still opens at 20:00 on the days the clocks change.
  sig { params(zone: ActiveSupport::TimeZone, day: Date, minute: Integer).returns(ActiveSupport::TimeWithZone) }
  def at_minute(zone, day, minute)
    day += minute / 1440
    zone.local(day.year, day.month, day.day, (minute % 1440) / 60, minute % 60)
  end

  sig { params(minute: Integer).returns(String) }
  def clock(minute)
    hour = (minute / 60) % 24
    suffix = hour < 12 ? "am" : "pm"
    twelve = hour % 12
    twelve = 12 if twelve.zero?
    (minute % 60).zero? ? "#{twelve}#{suffix}" : format("%<h>d:%<m>02d%<s>s", h: twelve, m: minute % 60, s: suffix)
  end

  sig { returns(String) }
  def day_names
    return "Every day" if days == EVERY_DAY
    return "Weekdays" if days == 0b0011111
    return "Weekends" if days == 0b1100000

    names = DAYS.each_with_index.select { |_, index| days.anybits?(1 << index) }.map(&:first)
    names.size == 1 ? "#{names.first}s" : names.map { |day| day.first(3) }.join(", ")
  end

  sig { void }
  def windowed
    return if base?

    errors.add(:base, "A timed block needs a start and an end") if start_minute.nil? || end_minute.nil?
    errors.add(:base, "A timed block can't start and end at the same time") if start_minute && start_minute == end_minute
    return unless layer_enum == Layer::Special

    errors.add(:base, "A special needs dates") if starts_on.nil? || ends_on.nil?
    errors.add(:base, "A special ends after it starts") if starts_on && ends_on && T.must(ends_on) < T.must(starts_on)
  end
end

# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe StationBlock do
  let(:zone) { ActiveSupport::TimeZone["America/New_York"] }

  def block(layer: "appointment", start: 20 * 60, finish: 21 * 60, days: StationBlock::EVERY_DAY, **attributes)
    described_class.new(layer: layer, ordering: "shuffle", days: days, start_minute: start, end_minute: finish, marathon_length: 3, **attributes)
  end

  describe "#next_start" do
    it "opens at the wall-clock time on the days the clocks change" do
      # US clocks spring forward on 8 March 2026 and fall back on 1 November.
      spring = block.next_start(zone.parse("2026-03-08 00:00"), zone)
      fall = block.next_start(zone.parse("2026-11-01 00:00"), zone)

      expect([ spring.hour, spring.min, spring.utc_offset ]).to eq([ 20, 0, -4.hours ])
      expect([ fall.hour, fall.min, fall.utc_offset ]).to eq([ 20, 0, -5.hours ])
    end

    it "keeps to its days and skips a window already begun" do
      mondays = block(days: 0b0000001)
      sunday_evening = zone.parse("2026-09-27 20:30")

      expect(mondays.next_start(sunday_evening, zone)).to eq(zone.parse("2026-09-28 20:00"))
    end

    it "looks no further than it's asked to" do
      mondays = block(days: 0b0000001)

      expect(mondays.next_start(zone.parse("2026-09-27 12:00"), zone, within: 1.hour)).to be_nil
    end

    it "is nil for the base, which never opens" do
      expect(block(layer: "base", start: nil, finish: nil).next_start(zone.now, zone)).to be_nil
    end
  end

  describe "#closes_after" do
    it "closes at the wall-clock time on the days the clocks change" do
      late = block(start: 22 * 60, finish: 1440)

      expect(late.closes_after(zone.parse("2026-03-08 22:30"), zone)).to eq(zone.parse("2026-03-09 00:00"))
      expect(block.closes_after(zone.parse("2026-11-01 20:15"), zone)).to eq(zone.parse("2026-11-01 21:00"))
    end

    it "closes the next morning for a window that runs past midnight" do
      overnight = block(start: 23 * 60, finish: 2 * 60)

      expect(overnight.closes_after(zone.parse("2026-09-27 23:30"), zone)).to eq(zone.parse("2026-09-28 02:00"))
      expect(overnight.closes_after(zone.parse("2026-09-28 01:00"), zone)).to eq(zone.parse("2026-09-28 02:00"))
    end
  end

  describe "#covers?" do
    it "covers a window past midnight under the day it started" do
      fridays_late = block(start: 23 * 60, finish: 2 * 60, days: 0b0010000)

      expect(fridays_late.covers?(zone.parse("2026-09-25 23:30"))).to be(true)  # Friday
      expect(fridays_late.covers?(zone.parse("2026-09-26 01:30"))).to be(true)  # early Saturday
      expect(fridays_late.covers?(zone.parse("2026-09-26 23:30"))).to be(false) # Saturday night
    end

    it "stays inside a special's dates" do
      special = block(layer: "special", starts_on: Date.new(2026, 12, 24), ends_on: Date.new(2026, 12, 25))

      expect(special.covers?(zone.parse("2026-12-24 20:30"))).to be(true)
      expect(special.covers?(zone.parse("2026-12-26 20:30"))).to be(false)
    end
  end

  describe "validation" do
    it "asks a timed block for a window, and a special for dates in order" do
      expect(block(start: nil).tap(&:valid?).errors[:base]).to include("A timed block needs a start and an end")
      expect(block(finish: 20 * 60).tap(&:valid?).errors[:base]).to include("A timed block can't start and end at the same time")
      expect(block(layer: "special").tap(&:valid?).errors[:base]).to include("A special needs dates")
      backwards = block(layer: "special", starts_on: Date.new(2026, 12, 25), ends_on: Date.new(2026, 12, 24))
      expect(backwards.tap(&:valid?).errors[:base]).to include("A special ends after it starts")
    end

    it "keeps minutes within a day" do
      expect(block(finish: 1441).tap(&:valid?).errors[:end_minute]).to be_present
    end
  end

  describe "#label" do
    it "names a block by its window when it has no name" do
      expect(block(layer: "daypart", start: 6 * 60, finish: (9 * 60) + 30).label).to eq("6am–9:30am")
      expect(block(days: 0b0011111).label).to eq("Weekdays at 8pm")
      expect(block(days: 0b0000100).label).to eq("Wednesdays at 8pm")
    end
  end
end

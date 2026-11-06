# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppSetting do
  describe "#quiet_hours?" do
    let(:setting) { described_class.new(optimize_quiet_start_hour: 1, optimize_quiet_end_hour: 6) }

    it "reads the hours on the household's clock, not the server's" do
      setting.time_zone = "America/New_York"
      # 03:00 in New York is 07:00 UTC; 23:00 in New York is 03:00 UTC.
      expect(setting.quiet_hours?(Time.utc(2026, 9, 27, 7).in_time_zone("UTC"))).to be(true)
      expect(setting.quiet_hours?(Time.utc(2026, 9, 28, 3).in_time_zone("UTC"))).to be(false)
    end

    it "falls back to the server's clock with no zone set" do
      expect(setting.quiet_hours?(Time.zone.parse("2026-09-27 03:00"))).to be(true)
      expect(setting.quiet_hours?(Time.zone.parse("2026-09-27 06:00"))).to be(false)
    end

    it "wraps past midnight, and treats equal hours as any time" do
      overnight = described_class.new(optimize_quiet_start_hour: 22, optimize_quiet_end_hour: 5)
      expect(overnight.quiet_hours?(Time.zone.parse("2026-09-27 23:00"))).to be(true)
      expect(overnight.quiet_hours?(Time.zone.parse("2026-09-27 04:59"))).to be(true)
      expect(overnight.quiet_hours?(Time.zone.parse("2026-09-27 12:00"))).to be(false)

      always = described_class.new(optimize_quiet_start_hour: 3, optimize_quiet_end_hour: 3)
      expect(always.quiet_hours?(Time.zone.parse("2026-09-27 12:00"))).to be(true)
    end
  end

  it "refuses a time zone it doesn't know" do
    expect(described_class.new(time_zone: "Mars/Olympus").tap(&:valid?).errors[:time_zone]).to be_present
  end
end

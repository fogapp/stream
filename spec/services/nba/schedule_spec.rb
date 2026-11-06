# typed: false
# frozen_string_literal: true

require "rails_helper"

# The NBA's schedule from ESPN's public scoreboard (PROPOSAL §7.8): a day
# asked for by its Eastern date, read once while it's cached, and the
# season's game days from its calendar.
RSpec.describe Nba::Schedule do
  let(:url) { "#{described_class::SCOREBOARD}?dates=20261021" }
  let(:body) do
    {
      leagues: [ { calendar: [ "2026-10-20T07:00Z", "2026-10-21T07:00Z", "2026-10-23T07:00Z" ] } ],
      events: [ { id: "401909088", status: { type: { state: "pre" } } } ]
    }
  end

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    stub_request(:get, url).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  it "reads a day's games and the season's game days in one request" do
    schedule = described_class.new

    expect(schedule.games(Date.new(2026, 10, 21)).pluck("id")).to eq([ "401909088" ])
    expect(schedule.game_days(Date.new(2026, 10, 21))).to eq([ Date.new(2026, 10, 20), Date.new(2026, 10, 21), Date.new(2026, 10, 23) ])
    expect(a_request(:get, url)).to have_been_made.once
  end

  it "answers Settings' Test with today's games" do
    allow(described_class).to receive(:today).and_return(Date.new(2026, 10, 21))

    expect(described_class.new.test_connection).to eq([ true, "Read NBA's schedule: 1 game today" ])
  end

  it "says what went wrong when ESPN doesn't answer" do
    stub_request(:get, url).to_return(status: 503)

    expect { described_class.new.games(Date.new(2026, 10, 21)) }.to raise_error(described_class::Error)
  end
end

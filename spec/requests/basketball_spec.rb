# typed: false
# frozen_string_literal: true

require "rails_helper"

# Basketball (PROPOSAL §7.8), with the NBA's schedule stubbed: there once the
# household turns on NBA League Pass, a day's games as matchups, each
# watched on NBA.com.
RSpec.describe "Basketball", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:schedule) { instance_double(Nba::Schedule) }

  def side(home_away, id, name, abbreviation, score:, points:)
    {
      "homeAway" => home_away, "score" => score.to_s, "winner" => false,
      "team" => { "id" => id, "displayName" => name, "shortDisplayName" => name.split.last, "location" => name.split.first,
                  "abbreviation" => abbreviation, "logo" => "https://a.espncdn.com/i/teamlogos/nba/500/scoreboard/#{abbreviation.downcase}.png",
                  "logoDark" => "https://a.espncdn.com/i/teamlogos/nba/500-dark/scoreboard/#{abbreviation.downcase}.png" },
      "records" => [ { "type" => "total", "summary" => "17-4" }, { "type" => "home", "summary" => "9-2" } ],
      "linescores" => points.each_with_index.map { |value, index| { "period" => index + 1, "value" => value.to_f } },
      "leaders" => [ { "name" => "points", "leaders" => [ { "value" => 21.0, "athlete" => { "shortName" => "J. Duren" } } ] } ]
    }
  end

  def game(state: "in", name: "STATUS_IN_PROGRESS", detail: "5:21 - 3rd")
    {
      "id" => "401810164", "date" => "2026-10-21T23:00Z", "season" => { "type" => 3 },
      "status" => { "period" => 3, "displayClock" => "5:21", "type" => { "name" => name, "state" => state, "shortDetail" => detail } },
      "competitions" => [ {
        "timeValid" => true, "venue" => { "fullName" => "Little Caesars Arena" },
        "notes" => [ { "headline" => "East 1st Round - Game 3" } ], "series" => { "summary" => "DET leads series 2-0" },
        "competitors" => [ side("home", "8", "Detroit Pistons", "DET", score: 70, points: [ 25, 25, 20 ]),
                           side("away", "1", "Atlanta Hawks", "ATL", score: 66, points: [ 22, 24, 20 ]) ],
        "broadcasts" => [ { "market" => "home", "names" => [ "FanDuel SN DET" ] },
                          { "market" => "away", "names" => [ "FanDuel SN SE", "NBA League Pass" ] },
                          { "market" => "national", "names" => [ "FanDuel SN DET" ] } ]
      } ]
    }
  end

  before do
    allow(Nba::Schedule).to receive(:new).and_return(schedule)
    allow(Nba::Schedule).to receive(:today).and_return(Date.new(2026, 10, 21))
  end

  context "without NBA League Pass" do
    it "isn't there" do
      get "/api/v1/basketball", headers: auth_headers(user)
      expect(json).to eq("available" => false)

      get "/api/v1/basketball/games", headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
      expect(json["errors"]).to eq([ "Turn on NBA League Pass in Settings › Integrations first" ])
    end
  end

  context "with NBA League Pass" do
    before { NbaSetting.create!(household: household) }

    it "is there for everyone in the household" do
      get "/api/v1/basketball", headers: auth_headers(user)
      expect(json).to eq("available" => true)
    end

    it "shows today's games as matchups, with the days either side that have games and where to watch them" do
      allow(schedule).to receive(:game_days).and_return([ Date.new(2026, 10, 20), Date.new(2026, 10, 21), Date.new(2026, 10, 23) ])
      allow(schedule).to receive(:games).with(Date.new(2026, 10, 21)).and_return([ game ])

      get "/api/v1/basketball/games", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(json).to include("date" => "2026-10-21", "today" => "2026-10-21", "previous_date" => "2026-10-20", "next_date" => "2026-10-23",
        "watch_url" => "https://www.nba.com/games?date=2026-10-21")
      card = json["games"].sole
      expect(card).to include("id" => "401810164", "state" => "live", "status" => "5:21 - 3rd", "period" => 3, "preseason" => false,
        "venue" => "Little Caesars Arena", "series" => { "name" => "East 1st Round - Game 3", "status" => "DET leads series 2-0" },
        "periods" => [ { "number" => 1, "away" => 22, "home" => 25 }, { "number" => 2, "away" => 24, "home" => 25 },
                       { "number" => 3, "away" => 20, "home" => 20 } ],
        "broadcasts" => [ { "name" => "FanDuel SN DET", "side" => "home" }, { "name" => "FanDuel SN SE", "side" => "away" },
                          { "name" => "NBA League Pass", "side" => "away" } ])
      expect(card["away"]).to include("score" => 66, "record" => "17-4", "leader" => { "name" => "J. Duren", "points" => 21 })
      expect(card["home"]["team"]).to include("id" => "8", "name" => "Detroit Pistons", "club" => "Pistons", "abbreviation" => "DET",
        "logo_url" => "https://a.espncdn.com/i/teamlogos/nba/500/scoreboard/det.png",
        "logo_dark_url" => "https://a.espncdn.com/i/teamlogos/nba/500-dark/scoreboard/det.png")
    end

    it "leaves the score off a game that hasn't started, and calls a postponed one off" do
      allow(schedule).to receive_messages(game_days: [ Date.new(2026, 10, 21) ],
        games: [ game(state: "pre", name: "STATUS_SCHEDULED", detail: "10/21 - 7:00 PM EDT"),
                 game(state: "post", name: "STATUS_POSTPONED", detail: "Postponed") ])

      get "/api/v1/basketball/games", headers: auth_headers(user)

      upcoming, postponed = json["games"]
      expect(upcoming).to include("state" => "upcoming")
      expect(upcoming["home"]["score"]).to be_nil
      expect(postponed).to include("state" => "off", "status" => "Postponed")
    end

    it "opens on the next day with games when today has none" do
      allow(schedule).to receive(:game_days).and_return([ Date.new(2026, 10, 20), Date.new(2026, 10, 23) ])
      allow(schedule).to receive(:games).with(Date.new(2026, 10, 23)).and_return([])

      get "/api/v1/basketball/games", headers: auth_headers(user)

      expect(json).to include("date" => "2026-10-23", "previous_date" => "2026-10-20", "next_date" => nil)
    end

    it "says so when the NBA's schedule can't be read" do
      allow(schedule).to receive(:game_days).and_raise(Nba::Schedule::Error, "NBA's schedule timed out")

      get "/api/v1/basketball/games", headers: auth_headers(user)

      expect(response).to have_http_status(:bad_gateway)
      expect(json["errors"]).to eq([ "NBA's schedule timed out" ])
    end

    # A rate limit is raised as the schedule's own error (tagged
    # RateLimitError), so it is a 502 saying so rather than a 500.
    it "says so when ESPN rate limits the schedule" do
      allow(Nba::Schedule).to receive(:new).and_call_original
      stub_request(:get, %r{site\.api\.espn\.com/apis/site/v2/sports/basketball/nba/scoreboard})
        .to_return(status: 429, body: { message: "Slow down" }.to_json, headers: { "Content-Type" => "application/json" })

      get "/api/v1/basketball/games", headers: auth_headers(user)

      expect(response).to have_http_status(:bad_gateway)
      expect(json["errors"]).to eq([ "NBA's schedule rate limited this request — Slow down" ])
    end
  end
end

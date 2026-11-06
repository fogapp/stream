# typed: false
# frozen_string_literal: true

require "rails_helper"

# Baseball (PROPOSAL §7.8), with MLB's schedule stubbed: there once the
# household has an MLB.tv account, a day's games as matchups, and a game
# played as its home or away team's stream — a stream like any other, read
# the first time it plays.
RSpec.describe "Baseball", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:schedule) { instance_double(Mlb::Schedule) }

  def side(id, name, abbreviation, score: nil)
    { "team" => { "id" => id, "name" => name, "clubName" => name.split.last, "shortName" => name.split.first, "abbreviation" => abbreviation },
      "leagueRecord" => { "wins" => 3, "losses" => 2 }, "score" => score, "probablePitcher" => { "fullName" => "Shane McClanahan" } }
  end

  def game(state: "Live", detailed: "In Progress", pk: 849_815)
    {
      "gamePk" => pk, "gameDate" => "2026-10-20T00:08:00Z", "gameType" => "L",
      "status" => { "abstractGameState" => state, "detailedState" => detailed },
      "teams" => { "away" => side(114, "Cleveland Guardians", "CLE", score: 2), "home" => side(139, "Tampa Bay Rays", "TB", score: 1) },
      "linescore" => { "currentInning" => 7, "currentInningOrdinal" => "7th", "inningState" => "Top", "outs" => 2, "balls" => 1, "strikes" => 2,
                       "offense" => { "first" => { "id" => 1 }, "third" => { "id" => 2 } },
                       "innings" => [ { "num" => 1, "away" => { "runs" => 2 }, "home" => { "runs" => 0 } } ],
                       "teams" => { "away" => { "hits" => 6, "errors" => 0 }, "home" => { "hits" => 4, "errors" => 1 } } },
      "seriesStatus" => { "shortDescription" => "ALCS Game 6", "result" => "TB leads 3-2" },
      "broadcasts" => [
        { "type" => "TV", "language" => "en", "callSign" => "TBS", "homeAway" => "home", "isNational" => true },
        { "type" => "TV", "language" => "en", "callSign" => "TBS", "homeAway" => "away", "isNational" => true },
        { "type" => "AM", "language" => "en", "callSign" => "WDAE", "homeAway" => "home" }
      ]
    }
  end

  before do
    allow(Mlb::Schedule).to receive(:new).and_return(schedule)
    allow(Mlb::Schedule).to receive(:today).and_return(Date.new(2026, 10, 19))
  end

  context "without an MLB.tv account" do
    it "isn't there" do
      get "/api/v1/baseball", headers: auth_headers(user)
      expect(json).to eq("available" => false)

      get "/api/v1/baseball/games", headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
      expect(json["errors"]).to eq([ "Sign in to MLB.tv in Settings › Integrations first" ])
    end
  end

  context "with an MLB.tv account" do
    before do
      allow(EnsureMlbTeamStreamsJob).to receive(:perform_later)
      MlbSetting.create!(household: household, username: "fan@example.com", password: "secret")
    end

    it "is there for everyone in the household" do
      get "/api/v1/baseball", headers: auth_headers(user)
      expect(json).to eq("available" => true)
    end

    it "shows today's games as matchups, with the days either side that have games" do
      allow(schedule).to receive(:game_days).and_return([ Date.new(2026, 10, 18), Date.new(2026, 10, 19), Date.new(2026, 10, 21) ])
      allow(schedule).to receive(:games).with(Date.new(2026, 10, 19)).and_return([ game ])

      get "/api/v1/baseball/games", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(json).to include("date" => "2026-10-19", "today" => "2026-10-19", "previous_date" => "2026-10-18", "next_date" => "2026-10-21")
      card = json["games"].sole
      expect(card).to include("id" => 849_815, "state" => "live", "status" => "In Progress", "watchable" => true,
        "series" => { "name" => "ALCS Game 6", "status" => "TB leads 3-2" },
        "inning" => { "number" => 7, "ordinal" => "7th", "half" => "top", "outs" => 2, "balls" => 1, "strikes" => 2,
                      "bases" => { "first" => true, "second" => false, "third" => true } },
        "innings" => [ { "number" => 1, "away" => 2, "home" => 0 } ],
        "broadcasts" => [ { "name" => "TBS", "side" => "national" } ])
      expect(card["away"]).to include("score" => 2, "hits" => 6, "record" => "3-2")
      expect(card["away"]["team"]).to include("id" => 114, "abbreviation" => "CLE", "club" => "Guardians",
        "logo_url" => "https://www.mlbstatic.com/team-logos/114.svg",
        "logo_png_url" => "https://img.mlbstatic.com/mlb-photos/image/upload/w_240,f_png,q_auto/v1/team/114/logo/spot/current")
    end

    it "opens on the next day with games when today has none" do
      allow(schedule).to receive(:game_days).and_return([ Date.new(2026, 10, 18), Date.new(2026, 10, 21) ])
      allow(schedule).to receive(:games).with(Date.new(2026, 10, 21)).and_return([])

      get "/api/v1/baseball/games", headers: auth_headers(user)

      expect(json).to include("date" => "2026-10-21", "previous_date" => "2026-10-18", "next_date" => nil)
    end

    it "says so when MLB's schedule can't be read" do
      allow(schedule).to receive(:game_days).and_raise(Mlb::Schedule::Error, "MLB's schedule timed out")

      get "/api/v1/baseball/games", headers: auth_headers(user)

      expect(response).to have_http_status(:bad_gateway)
      expect(json["errors"]).to eq([ "MLB's schedule timed out" ])
    end

    it "plays a game as the chosen team's stream, made once, in no library" do
      allow(schedule).to receive(:game).with(849_815).and_return(game)

      post "/api/v1/baseball/games/849815/watch", params: { side: "away" }, headers: auth_headers(user), as: :json
      expect(response).to have_http_status(:ok)
      stream = LiveStream.find(json["live_stream_id"])
      expect(stream).to have_attributes(name: "Cleveland Guardians", mlb_team_id: 114, kind: "mlb", library_id: nil, feed: nil,
        url: LiveStream::TEAM_URL)

      post "/api/v1/baseball/games/849815/watch", params: { side: "away" }, headers: auth_headers(user), as: :json
      expect(json["live_stream_id"]).to eq(stream.id)
      post "/api/v1/baseball/games/849815/watch", params: { side: "home" }, headers: auth_headers(user), as: :json
      expect(LiveStream.find(json["live_stream_id"])).to have_attributes(name: "Tampa Bay Rays", mlb_team_id: 139)
    end

    it "won't play a game that hasn't reached its warm-up" do
      allow(schedule).to receive(:game).and_return(game(state: "Preview", detailed: "Scheduled"))

      post "/api/v1/baseball/games/849815/watch", params: { side: "home" }, headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"]).to eq([ "MLB.tv starts this game's broadcast shortly before first pitch" ])
      expect(LiveStream.count).to eq(0)
    end

    it "keeps team streams out of the streams an admin added, but lets a kid's profile play one" do
      library = Library.create!(household: household, name: "Cameras", kind: "live")
      LiveStream.create!(household: household, library: library, name: "Front door", kind: "camera", url: "rtsp://192.168.1.5/live")
      team = Mlb::TeamStreams.for(household.id, 114, "Cleveland Guardians")

      get "/api/v1/live_streams", headers: auth_headers(user)
      expect(json.pluck("name")).to eq([ "Front door" ])

      kid = Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 10, library_ids: [ library.id ])

      Current.profile = kid
      expect(Viewing::Access.allows?(team)).to be(true)
    ensure
      Current.reset
    end
  end
end

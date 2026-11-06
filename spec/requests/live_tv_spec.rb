# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Grid", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }
  let(:library) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }

  def show(title, episodes:, minutes: 22, content_rating: nil)
    Show.create!(household: household, library: library, folder: title, title: title, content_rating: content_rating).tap do |series|
      season = series.seasons.create!(season_number: 1)
      (1..episodes).each do |number|
        file = MediaFile.create!(household: household, library: library, path: "/tv/#{title}/#{number}.mkv", size: 1,
          mtime: Time.current, state: "probed", duration_seconds: minutes * 60.0)
        series.episodes.create!(season: season, season_number: 1, episode_number: number, title: "#{title} #{number}")
          .editions.create!(media_file: file)
      end
    end
  end

  def create_station(number, name, source = {})
    post "/api/v1/stations", params: { number: number, name: name, blocks: [ { layer: "base", source: source, ordering: "sequential" } ] },
      headers: auth_headers(admin), as: :json
    expect(response).to have_http_status(:created)
    Station.find(json["id"])
  end

  # Scheduling reads the clock: a fixed mid-week noon, so no run lands on a
  # change of clocks or a week's edge.
  let(:midweek) { Time.utc(2026, 9, 23, 16) }

  describe "channels" do
    before { travel_to midweek }

    it "are made by an admin, scheduled at once, and listed in number order" do
      show("Seinfeld", episodes: 50)
      create_station("12", "Sitcoms")
      expect(json).to include("number" => "12", "name" => "Sitcoms", "last_error" => nil)
      expect(json["blocks"].sole).to include("layer" => "base", "ordering" => "sequential", "label" => "The channel's mix")
      create_station("4.1", "More")

      get "/api/v1/stations", headers: auth_headers(member)
      expect(json.map { |station| station["number"] }).to eq(%w[4.1 12])
      expect(Station.find_by(number: "12").airings.count).to be > 100

      post "/api/v1/stations", params: { number: "12", name: "Again" }, headers: auth_headers(admin), as: :json
      expect(json["errors"]).to include("Number is already another channel's")
      post "/api/v1/stations", params: { number: "12", name: "Again" }, headers: auth_headers(member), as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "rebuilds from the end of what's on when edited" do
      show("Seinfeld", episodes: 50)
      station = create_station("4", "Seinfeld")
      on_now = station.airing_at(Time.current)
      later = station.airings.where("starts_at > ?", Time.current).count

      patch "/api/v1/stations/#{station.id}", params: { name: "Seinfeld TV", blocks: [ { layer: "base", ordering: "shuffle" } ] },
        headers: auth_headers(admin), as: :json
      expect(response).to have_http_status(:ok)
      expect(station.reload.airing_at(Time.current)).to eq(on_now)
      expect(station.airings.where("starts_at > ?", Time.current).count).to be_within(3).of(later)
      expect(station.station_blocks.sole.ordering).to eq("shuffle")
    end

    it "says who won't see a channel because of what plays between its programs, as the guide will" do
      series = show("Seinfeld", episodes: 30, content_rating: "TV-PG")
      film = Movie.create!(household: household, library: library, title: "Heat", content_rating: "R")
      trailer = MediaFile.create!(household: household, library: library, path: "/tv/heat-trailer.mkv", size: 1, mtime: Time.current,
        state: "probed", duration_seconds: 120)
      Extra.create!(household: household, owner: film, kind: "trailer", title: "Heat trailer", media_file: trailer)
      Profile.default_for(household)
      Profile.create!(household: household, name: "Junior", kind: "kid", max_rating_age: 10, position: 2)

      post "/api/v1/stations/preview", params: { number: "9", name: "New", snap_minutes: 30, filler: "extras", blocks: [
        { layer: "base", source: { show_ids: [ series.id ] }, ordering: "sequential" }
      ] }, headers: auth_headers(admin), as: :json

      expect(json["airings"].map { |airing| airing["title"] }).to include("Heat trailer")
      expect(json["warnings"].map { |warning| warning["text"] }).to include(a_string_matching(/Junior.*won't see this channel: it airs R\./))
    end

    it "previews a week of new programming without keeping any of it, and says what's worth knowing" do
      # Mid-week: from Sunday ~7:50pm to 9pm the channel's current program
      # holds tonight's 8pm slot, and next Sunday's falls past the week.
      travel_to Time.utc(2026, 9, 23, 12) # earlier than the describe's: the comment's timings depend on it
      breaking = show("Breaking Bad", episodes: 1, minutes: 47, content_rating: "TV-MA")
      show("Seinfeld", episodes: 10, content_rating: "TV-PG")
      station = create_station("4", "Seinfeld", { show_ids: [ Show.find_by(title: "Seinfeld").id ] })
      Profile.default_for(household)
      # After the grown-up: under travel_to both would share a created_at, and
      # the household's default profile would be a coin toss.
      Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 7, position: 1)
      before = station.airings.order(:starts_at).pluck(:id)

      post "/api/v1/stations/preview", params: { station_id: station.id, name: "Seinfeld", number: "4", blocks: [
        { layer: "base", source: { exclude_show_ids: [ breaking.id ] }, ordering: "shuffle" },
        { layer: "appointment", days: 64, start_minute: 1200, end_minute: 1260, source: { show_ids: [ breaking.id ] }, ordering: "sequential",
          loops: false },
        { layer: "daypart", start_minute: 360, end_minute: 480, source: { genres: [ "Western" ] }, ordering: "shuffle" }
      ] }, headers: auth_headers(admin), as: :json
      expect(response).to have_http_status(:ok)
      expect(json["airings"].size).to be > 100
      expect(json["airings"].map { |airing| airing["block_index"] }.uniq).to include(0)
      texts = json["warnings"].map { |warning| warning["text"] }
      expect(texts).to include(a_string_matching(/Nothing in the library matches “6am–8am”/))
      expect(texts).to include(a_string_matching(/Breaking Bad runs out in “Sundays at 8pm”/))
      expect(texts).to include(a_string_matching(/“The channel's mix” has \d+ (hours|minutes) of programs/))
      expect(texts).to include("Kid won't see this channel: it airs TV-MA.")

      expect(station.reload.station_blocks.count).to eq(1)
      expect(station.airings.order(:starts_at).pluck(:id)).to eq(before)
      expect(Station.count).to eq(1)

      # A channel not made yet is planned under a number no channel has, so
      # the preview never holds "9" while a save of channel 9 waits on it.
      planned_as = []
      allow(Stations::Scheduler).to receive(:new).and_wrap_original do |original, planned, **options|
        planned_as << planned.number
        original.call(planned, **options)
      end
      post "/api/v1/stations/preview", params: { number: "9", name: "New", blocks: [ { layer: "base", ordering: "shuffle" } ] },
        headers: auth_headers(admin), as: :json
      expect(json["airings"]).not_to be_empty
      expect(Station.count).to eq(1)
      expect(planned_as.sole).to match(/\A\d{4}\.\d{2}\z/)

      # The number is still checked as asked for.
      post "/api/v1/stations/preview", params: { number: station.number, name: "Twin", blocks: [] }, headers: auth_headers(admin), as: :json
      expect(json["errors"]).to include("Number is already another channel's")
    end

    it "offers the library's own genres, networks and keywords to choose from" do
      Show.create!(household: household, library: library, folder: "a", title: "The Office", networks: [ "NBC" ], genres: [ "Comedy" ],
        keywords: [ "sitcom" ])
      Show.create!(household: household, library: library, folder: "b", title: "Frasier", networks: [ "NBC" ], genres: [ "Comedy" ])
      Profile.create!(household: create_household(name: "Elsewhere"), name: "Neighbour")
      get "/api/v1/stations/options", headers: auth_headers(admin)
      expect(json["networks"]).to eq([ { "value" => "NBC", "count" => 2 } ])
      expect(json["keywords"]).to eq([ { "value" => "sitcom", "count" => 1 } ])
      expect(json["shows"].map { |row| row["title"] }).to eq([ "Frasier", "The Office" ])
      # Whose watching an unwatched block counts: this household's profiles only.
      expect(json["profiles"].map { |row| row["name"] }).to match_array(Profile.unscoped.where(household: household).pluck(:name))
      expect(json["profiles"].map { |row| row["name"] }).not_to include("Neighbour")
    end
  end

  describe "the guide" do
    before { travel_to midweek }

    it "shows each channel's airings in the window, with titles and why" do
      show("Seinfeld", episodes: 50)
      station = create_station("4", "Seinfeld")

      get "/api/v1/guide", headers: auth_headers(member)
      row = json["stations"].sole
      expect(row).to include("id" => station.id, "number" => "4")
      expect(row["airings"].first).to include("kind" => "episode", "title" => "Seinfeld", "subtitle" => "S01E01 · Seinfeld 1",
        "reason" => "The channel's mix · next in order")
      expect(Time.zone.parse(row["airings"].first["starts_at"])).to be <= Time.current
      expect(Time.zone.parse(row["airings"].last["starts_at"])).to be < 3.hours.from_now
    end

    it "leaves out a channel a profile hid, and one with anything past a kid's ceiling" do
      show("Bluey", episodes: 20, content_rating: "TV-Y")
      show("The Sopranos", episodes: 20, content_rating: "TV-MA")
      kids = create_station("2", "Kids", { show_ids: [ Show.find_by(title: "Bluey").id ] })
      grown = create_station("9", "Grown-ups", { show_ids: [ Show.find_by(title: "The Sopranos").id ] })
      kid = Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 7)
      mine = Profile.create!(household: household, name: "Me")

      get "/api/v1/guide", headers: auth_headers(member).merge(profile_header(kid))
      expect(json["stations"].map { |row| row["name"] }).to eq([ "Kids" ])
      post "/api/v1/playback_sessions", params: { station_id: grown.id }, headers: auth_headers(member).merge(profile_header(kid))
      expect(response).to have_http_status(:not_found)

      put "/api/v1/stations/#{kids.id}/hide", headers: auth_headers(member).merge(profile_header(mine))
      get "/api/v1/guide", headers: auth_headers(member).merge(profile_header(mine))
      expect(json["stations"].map { |row| row["name"] }).to eq([ "Grown-ups" ])
      get "/api/v1/stations", params: { hidden: 1 }, headers: auth_headers(member).merge(profile_header(mine))
      expect(json.map { |row| [ row["name"], row["hidden"] ] }).to eq([ [ "Kids", true ], [ "Grown-ups", false ] ])

      delete "/api/v1/stations/#{kids.id}/hide", headers: auth_headers(member).merge(profile_header(mine))
      get "/api/v1/guide", headers: auth_headers(member).merge(profile_header(mine))
      expect(json["stations"].size).to eq(2)
    end
  end

  describe "a profile's own marks" do
    let(:profile) { Profile.create!(household: household, name: "Me") }
    let(:headers) { auth_headers(member).merge(profile_header(profile)) }

    it "favourites a channel, flagged in the guide" do
      show("Seinfeld", episodes: 30)
      station = create_station("4", "Seinfeld")
      put "/api/v1/stations/#{station.id}/favorite", headers: headers
      get "/api/v1/guide", headers: headers
      expect(json["stations"].sole).to include("favorite" => true)
      delete "/api/v1/stations/#{station.id}/favorite", headers: headers
      get "/api/v1/guide", headers: headers
      expect(json["stations"].sole).to include("favorite" => false)
    end

    it "reminds of a program just before it starts, once, in the app" do
      show("Seinfeld", episodes: 30)
      station = create_station("4", "Seinfeld")
      later = station.airings.where("starts_at > ?", 1.hour.from_now).order(:starts_at).first

      put "/api/v1/airings/#{later.id}/reminder", headers: headers
      expect(response).to have_http_status(:no_content)
      job = enqueued_jobs.find { |queued| queued["job_class"] == "RemindAiringJob" }
      expect(Time.zone.at(job["scheduled_at"].is_a?(String) ? Time.zone.parse(job["scheduled_at"]) : job["scheduled_at"]))
        .to be_within(1.second).of(later.starts_at - 2.minutes)

      get "/api/v1/guide", params: { from: later.starts_at.iso8601, to: (later.starts_at + 1.minute).iso8601 }, headers: headers
      expect(json["stations"].sole["airings"].first).to include("id" => later.id, "reminded" => true)

      reminder = AiringReminder.sole
      2.times { RemindAiringJob.perform_now(reminder.id) }
      notice = Notification.where(user: member).sole
      expect(notice).to have_attributes(kind: "live_reminder", path: "/live/4")
      expect(notice.title).to start_with("Seinfeld S01E")

      delete "/api/v1/airings/#{later.id}/reminder", headers: headers
      expect(AiringReminder.count).to eq(0)
    end

    it "won't remind of something already on" do
      show("Seinfeld", episodes: 30)
      station = create_station("4", "Seinfeld")
      put "/api/v1/airings/#{station.airing_at(Time.current).id}/reminder", headers: headers
      expect(response).to have_http_status(:conflict)
    end
  end

  describe "tuning in" do
    before { require_ffprobe! }

    def json_events_url(session) = "/media/s/#{Playback::StreamToken.issue(session)}/events"

    let(:profile) { Profile.create!(household: household, name: "Me") }
    let(:headers) { auth_headers(member).merge(profile_header(profile)) }
    let(:episode) do
      series = Show.create!(household: household, library: library, folder: "Heat", title: "Heat")
      root = build_root("Heat/1.mp4" => "h264_aac.mp4")
      file = MediaFile.create!(household: household, library: library, path: File.join(root, "Heat/1.mp4"), size: 1, mtime: Time.current,
        state: "probed")
      Media::FileProber.new(file).call
      series.episodes.create!(season: series.seasons.create!(season_number: 1), season_number: 1, episode_number: 1, title: "Pilot")
        .tap { |made| made.editions.create!(media_file: file) }
    end
    let(:station) { Station.create!(household: household, number: "7", name: "Heat") }

    def airing(starts_at, seconds)
      Airing.create!(household: household, station: station, playable: episode, media_file: episode.media_files.first,
        series_key: episode.show_id, starts_at: starts_at, ends_at: starts_at + seconds, reason: "Test")
    end

    it "joins what's on where live is, and never Continue watching" do
      on = airing(Time.current - 3.seconds, 3600)
      post "/api/v1/playback_sessions", params: { station_id: station.id }, headers: headers
      expect(response).to have_http_status(:created)
      expect(json["resume_at"]).to be_within(1.5).of(3.0)
      expect(json["next_up"]).to be_nil
      expect(json["live"]).to include("station_id" => station.id, "number" => "7", "airing_id" => on.id)
      session = PlaybackSession.find(json["id"])
      expect(session).to have_attributes(airing_id: on.id)

      post json["progress_url"], params: { position: 4.0 }, as: :json
      expect(WatchState.find_by(profile: profile, playable: episode)).to be_nil
    end

    it "restarts from the beginning, but can't get ahead of live" do
      on = airing(Time.current - 2.seconds, 3600)
      post "/api/v1/playback_sessions", params: { airing_id: on.id, start: 0 }, headers: headers
      expect(json["resume_at"]).to eq(0.0)
      post "/api/v1/playback_sessions", params: { airing_id: on.id, start: 500 }, headers: headers
      expect(json["resume_at"]).to be <= 3.0
    end

    it "counts as watched when seen to the end, having seen at least half" do
      duration = episode.media_files.first.duration_seconds
      airing(Time.current - 1.second, 3600)
      post "/api/v1/playback_sessions", params: { station_id: station.id, start: 0 }, headers: headers
      post json["progress_url"], params: { position: duration }, as: :json
      expect(WatchState.find_by(profile: profile, playable: episode)).to be_completed
    end

    it "doesn't put the show in Next up — that's for what was chosen to watch" do
      file = MediaFile.create!(household: household, library: library, path: "/nowhere/Heat/2.mp4", size: 1, mtime: Time.current, state: "probed")
      episode.show.episodes.create!(season: episode.season, season_number: 1, episode_number: 2, title: "Second")
        .editions.create!(media_file: file)
      airing(Time.current - 1.second, 3600)
      post "/api/v1/playback_sessions", params: { station_id: station.id, start: 0 }, headers: headers
      post json["progress_url"], params: { position: episode.media_files.first.duration_seconds }, as: :json
      expect(WatchState.find_by(profile: profile, playable: episode)).to be_completed

      get "/api/v1/home", headers: headers
      expect(json["hubs"].find { |hub| hub["key"] == "next_up" }&.dig("items").to_a).to be_empty

      Playback::Progress.mark(profile, episode, watched: true)
      get "/api/v1/home", headers: headers
      expect(json["hubs"].find { |hub| hub["key"] == "next_up" }["items"].map { |item| item["title"] }).to eq([ "Second" ])
    end

    it "tunes a neighbouring channel ahead on standby — not a play until switched to" do
      on = airing(Time.current - 3.seconds, 3600)
      post "/api/v1/playback_sessions", params: { station_id: station.id, standby: true }, headers: headers
      expect(response).to have_http_status(:created)
      session = PlaybackSession.find(json["id"])
      expect(session).to have_attributes(standby: true, airing_id: on.id)
      expect(session.playback_events).to be_empty
      expect(PlaybackSession.watched).to be_empty

      post "/api/v1/playback_sessions/#{session.id}/watch", params: { position: 12.5 }, headers: headers
      expect(response).to have_http_status(:no_content)
      expect(session.reload).to have_attributes(standby: false, joined_at_seconds: 12.5)
      expect(session.playback_events.sole).to have_attributes(kind: "start", position_seconds: 12.5)

      post json_events_url(session), params: { events: [ { kind: "tune", position: 12.5, detail: { ms: 14, ready: true } } ] }, as: :json
      get "/api/v1/playback_decisions/summary", headers: auth_headers(admin)
      expect(json["channel_changes"]).to include("count" => 1, "ready" => 1, "median_ms" => 14)
    end

    it "times each program giving way to the next, for the Playback decisions page" do
      airing(Time.current - 3.seconds, 3600)
      post "/api/v1/playback_sessions", params: { station_id: station.id }, headers: headers
      session = PlaybackSession.find(json["id"])
      post json_events_url(session), params: { events: [
        { kind: "transition", position: 0, detail: { ms: 40, via: "ended", ready: true } },
        { kind: "transition", position: 0, detail: { ms: 900, via: "watchdog", ready: false } },
        { kind: "transition", position: 0, detail: { ms: 600_000, via: "gap", ready: true } }
      ] }, as: :json
      get "/api/v1/playback_decisions/summary", headers: auth_headers(admin)
      expect(json["program_changes"]).to include("count" => 3, "ready" => 2, "watchdog" => 1, "median_ms" => 40, "p90_ms" => 900)
    end

    it "goes back on standby when changed away from — still playable for Last, and watched again when switched back to" do
      airing(Time.current - 3.seconds, 3600)
      post "/api/v1/playback_sessions", params: { station_id: station.id }, headers: headers
      session = PlaybackSession.find(json["id"])
      token = Playback::StreamToken.issue(session)

      post "/api/v1/playback_sessions/#{session.id}/standby", params: { position: 20.0 }, headers: headers
      expect(response).to have_http_status(:no_content)
      expect(session.reload).to have_attributes(standby: true, state: "active", position_seconds: 20.0)
      expect(session.playback_events.order(:created_at).map(&:kind)).to eq(%w[start stop])
      expect(PlaybackSession.watched).to be_empty
      expect(Playback::StreamToken.verify(token)).to eq(session)

      post "/api/v1/playback_sessions/#{session.id}/watch", params: { position: 30.0 }, headers: headers
      expect(session.reload).to have_attributes(standby: false, joined_at_seconds: 30.0)
    end

    it "keeps a channel held on standby seen, without another stop, when the deck says it's still there" do
      airing(Time.current - 3.seconds, 3600)
      post "/api/v1/playback_sessions", params: { station_id: station.id, standby: true }, headers: headers
      session = PlaybackSession.find(json["id"])
      session.update_columns(last_seen_at: 10.minutes.ago)

      post "/api/v1/playback_sessions/#{session.id}/standby", params: { position: 99.0 }, headers: headers
      expect(response).to have_http_status(:no_content)
      expect(session.reload.last_seen_at).to be > 1.minute.ago
      expect(session).to have_attributes(standby: true, state: "active")
      expect(session.playback_events.where(kind: "stop")).to be_empty
    end

    it "won't tune a channel ahead that would need converting" do
      airing(Time.current - 3.seconds, 3600)
      episode.media_files.first.media_streams.where(kind: "video").update_all(codec: "mpeg2video")
      post "/api/v1/playback_sessions", params: { station_id: station.id, standby: true, capabilities: { "video" => %w[h264], "audio" => %w[aac],
        "containers" => %w[mp4], "hls" => "mse", "max_audio_channels" => 2, "hdr" => [], "max_height" => 1080 } }, headers: headers, as: :json
      expect(response).to have_http_status(:conflict)
      expect(json["errors"]).to eq([ "This channel needs converting, so it isn't tuned ahead" ])
      expect(PlaybackSession.count).to eq(0)
    end

    it "joins a later part of a program partway into its file, can go back to its first part, and counts the whole as watched" do
      duration = episode.media_files.first.duration_seconds
      first = Airing.create!(household: household, station: station, playable: episode, media_file: episode.media_files.first,
        series_key: episode.show_id, starts_at: 10.minutes.ago, ends_at: 10.minutes.ago + 1.second, media_start: 0.0, media_end: 1.0, reason: "Test")
      second = Airing.create!(household: household, station: station, playable: episode, media_file: episode.media_files.first,
        series_key: episode.show_id, starts_at: 1.second.ago, ends_at: 1.hour.from_now, media_start: 1.0, reason: "Test")
      expect(second.parts).to eq([ first, second ])

      post "/api/v1/playback_sessions", params: { station_id: station.id }, headers: headers
      expect(response).to have_http_status(:created), response.body
      expect(json["resume_at"]).to be_within(1).of(2.0)
      expect(json["live"]).to include("airing_id" => second.id, "media_start" => 1.0, "media_end" => nil)

      # Restart: the program's first part, behind live.
      post "/api/v1/playback_sessions", params: { airing_id: first.id, start: 0 }, headers: headers
      expect(response).to have_http_status(:created)
      expect(json["resume_at"]).to eq(0.0)
      post json["progress_url"], params: { position: 1.0 }, as: :json

      post "/api/v1/playback_sessions", params: { airing_id: second.id, start: 1.0 }, headers: headers
      post json["progress_url"], params: { position: duration }, as: :json
      expect(WatchState.find_by(profile: profile, playable: episode)).to be_completed
    end

    it "says so when nothing's on, and when to ask again" do
      airing(Time.current + 10.minutes, 600)
      post "/api/v1/playback_sessions", params: { station_id: station.id }, headers: headers
      expect(response).to have_http_status(:conflict)
      expect(json["errors"]).to eq([ "Nothing's on this channel right now" ])
      expect(response.headers["Retry-After"].to_i).to be_within(2).of(600)
    end

    it "says what follows the airing it tunes to" do
      on = airing(Time.current - 3.seconds, 60)
      after = airing(on.ends_at, 60)
      post "/api/v1/playback_sessions", params: { station_id: station.id }, headers: headers
      expect(json["live"]).to include("airing_id" => on.id, "next_airing_id" => after.id, "next_starts_at" => after.starts_at.iso8601(3))
    end

    it "joins what follows rather than an airing's last seconds" do
      on = airing(Time.current - 55.seconds, 60)
      after = airing(on.ends_at, 600)
      post "/api/v1/playback_sessions", params: { station_id: station.id }, headers: headers
      expect(response).to have_http_status(:created)
      expect(json["live"]).to include("airing_id" => after.id)
      expect(json["resume_at"]).to eq(0.0)
    end

    it "keeps an airing's last seconds when a gap follows it" do
      on = airing(Time.current - 55.seconds, 60)
      airing(on.ends_at + 5.minutes, 600)
      post "/api/v1/playback_sessions", params: { station_id: station.id }, headers: headers
      expect(json["live"]).to include("airing_id" => on.id)
    end

    describe "the program after one" do
      it "plays what follows, as far behind live as the viewer was" do
        before = airing(Time.current - 70.seconds, 60)
        after = airing(before.ends_at, 600)
        post "/api/v1/playback_sessions", params: { after_airing_id: before.id, behind: 4 }, headers: headers
        expect(response).to have_http_status(:created), response.body
        expect(json["live"]).to include("airing_id" => after.id)
        expect(json["resume_at"]).to be_within(1).of(6.0)
      end

      it "starts it a few seconds early, when the file before ran out before its slot did" do
        before = airing(Time.current - 57.seconds, 60)
        after = airing(before.ends_at, 600)
        post "/api/v1/playback_sessions", params: { after_airing_id: before.id }, headers: headers
        expect(response).to have_http_status(:created)
        expect(json["live"]).to include("airing_id" => after.id)
        expect(json["resume_at"]).to eq(0.0)
      end

      it "is a slate until a later one starts, saying when — though it can be tuned ahead" do
        before = airing(Time.current - 50.seconds, 60)
        after = airing(before.ends_at + 30.seconds, 600)
        post "/api/v1/playback_sessions", params: { after_airing_id: before.id }, headers: headers
        expect(response).to have_http_status(:conflict)
        expect(json["errors"]).to eq([ "That hasn't started yet" ])
        expect(response.headers["Retry-After"].to_i).to be_within(1).of(40)

        post "/api/v1/playback_sessions", params: { after_airing_id: before.id, standby: true }, headers: headers
        expect(response).to have_http_status(:created)
        expect(json["live"]).to include("airing_id" => after.id)
        expect(PlaybackSession.find(json["id"])).to have_attributes(standby: true)
      end

      it "follows the schedule as it is now, after an edit replaced what came next" do
        before = airing(Time.current - 61.seconds, 60)
        airing(before.ends_at, 600).delete
        replacement = airing(before.ends_at, 300)
        post "/api/v1/playback_sessions", params: { after_airing_id: before.id }, headers: headers
        expect(json["live"]).to include("airing_id" => replacement.id)
      end

      it "says so when nothing follows" do
        before = airing(Time.current - 61.seconds, 60)
        post "/api/v1/playback_sessions", params: { after_airing_id: before.id }, headers: headers
        expect(response).to have_http_status(:conflict)
        expect(json["errors"]).to eq([ "Nothing's on this channel right now" ])
        expect(response.headers["Retry-After"]).to be_nil
      end
    end
  end

  it "keeps every network a show aired on, films' studios, and both's keywords" do
    series = Show.create!(household: household, library: library, folder: "Office", title: "The Office")
    Catalog::Metadata.apply_show(series, tmdb_show(id: 2316, name: "The Office", date: "2005-03-24").merge(
      "networks" => [ { "name" => "NBC" }, { "name" => "Peacock" } ], "keywords" => { "results" => [ { "name" => "sitcom" } ] }
    ))
    expect(series.reload).to have_attributes(network: "NBC", networks: %w[NBC Peacock], keywords: [ "sitcom" ])

    film = Movie.create!(household: household, library: library, title: "Heat")
    Catalog::Metadata.apply_movie(film, tmdb_movie(id: 949, title: "Heat", date: "1995-12-15",
      production_companies: [ { "name" => "Regency" }, { "name" => "Forward Pass" } ], keywords: { "keywords" => [ { "name" => "heist" } ] }))
    expect(film.reload).to have_attributes(studios: [ "Regency", "Forward Pass" ], keywords: [ "heist" ])
  end

  it "keeps every channel three days ahead each night" do
    show("Seinfeld", episodes: 400)
    station = Station.create!(household: household, number: "4", name: "Four")
    station.station_blocks.create!(layer: "base", source: {}, ordering: "shuffle")
    travel_to midweek
    perform_enqueued_jobs { ScheduleStationsJob.perform_now }
    expect(station.reload.scheduled_through).to be >= midweek + 3.days - 1.minute
    before = station.airings.order(:starts_at).pluck(:id)

    travel_to midweek + 1.day
    perform_enqueued_jobs { ScheduleStationsJob.perform_now }
    expect(station.airings.order(:starts_at).pluck(:id).first(before.size)).to eq(before)
    expect(station.reload.scheduled_through).to be >= midweek + 4.days - 1.minute
  end
end

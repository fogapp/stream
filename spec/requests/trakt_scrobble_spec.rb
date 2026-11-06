# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Scrobbling to Trakt", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:household) { create_household }
  let(:profile) { Profile.default_for(household) }
  let(:library) { create_library(household: household, roots: build_root) }
  let(:movie) { Movie.create!(household: household, library: library, title: "Heat", year: 1995, tmdb_id: 949) }
  let(:file) do
    MediaFile.create!(household: household, library: library, path: "/movies/heat.mkv", size: 1, mtime: Time.current, state: "probed",
      duration_seconds: 1000.0).tap { |media_file| movie.editions.create!(media_file: media_file) }
  end
  let(:session) do
    PlaybackSession.create!(household: household, profile: profile, playable: movie, media_file: file, method: "direct", decision: {}, device_name: "Den",
      started_at: Time.current, last_seen_at: Time.current)
  end
  let(:progress_url) { "/media/s/#{Playback::StreamToken.issue(session)}/progress" }
  let(:scrobbles) { [] }

  before do
    TraktSetting.create!(household: household, client_id: "client-abc", client_secret: "secret-xyz")
    TraktAccount.create!(household: household, profile: profile, state: "linked", access_token: "at-1", refresh_token: "rt-1",
      expires_at: 1.day.from_now)
    stub_request(:post, %r{\Ahttps://api\.trakt\.tv/scrobble/}).to_return do |request|
      scrobbles << [ request.uri.path.delete_prefix("/scrobble/"), JSON.parse(request.body)["progress"] ]
      { status: 201, body: "{}" }
    end
    allow_any_instance_of(Trakt::Api).to receive(:sleep) # rubocop:disable RSpec/AnyInstance
  end

  def report(position, ended: false)
    post progress_url, params: { position: position, ended: ended }, as: :json
    perform_enqueued_jobs
  end

  it "starts on the first report, and stops once Stream counts it watched" do
    report(10)
    report(20)
    report(950)
    report(990)
    expect(scrobbles).to eq([ [ "start", 1.0 ], [ "stop", 95.0 ] ])
    expect(session.reload.trakt_scrobble).to eq("done")
    # The scrobble is the play: nothing more for the history.
    expect(TraktChange.count).to eq(0)
  end

  it "pauses a play that ends early" do
    report(300)
    report(400, ended: true)
    expect(scrobbles).to eq([ [ "start", 30.0 ], [ "pause", 40.0 ] ])
  end

  it "pauses a play whose player goes quiet, and starts it again when it's back" do
    report(500)
    travel(30.seconds) { TraktScrobbleSweepJob.perform_now }
    travel(2.minutes) { TraktScrobbleSweepJob.perform_now }
    perform_enqueued_jobs
    report(510)
    expect(scrobbles).to eq([ [ "start", 50.0 ], [ "pause", 50.0 ], [ "start", 51.0 ] ])
  end

  it "doesn't scrobble a profile that isn't linked" do
    TraktAccount.delete_all
    report(10)
    expect(scrobbles).to eq([])
    expect(session.reload.trakt_scrobble).to be_nil
  end

  it "takes a stop Trakt already has as done" do
    stub_request(:post, "https://api.trakt.tv/scrobble/stop").to_return(status: 409, body: "{}")
    report(950)
    expect(session.reload.trakt_scrobble).to eq("done")
    expect(TraktChange.count).to eq(0)
  end

  it "sends a stop Trakt never took to its history instead" do
    stub_request(:post, "https://api.trakt.tv/scrobble/stop").to_return(status: 503, body: "")
    history = stub_request(:post, "https://api.trakt.tv/sync/history").to_return(status: 201, body: "{}")
    report(950)
    # Each retry is queued for later.
    perform_enqueued_jobs while enqueued_jobs.any?
    expect(history).to have_been_requested
    expect(TraktChange.count).to eq(0)
  end
end

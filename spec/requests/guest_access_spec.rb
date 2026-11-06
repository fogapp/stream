# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Guest access", type: :request do
  let(:household) { create_household }
  let(:guest) { create_user(household: household, role: "guest") }

  it "lets a guest read" do
    get "/api/v1/notifications", headers: auth_headers(guest)
    expect(response).to have_http_status(:ok)
  end

  it "refuses a guest's change and changes nothing" do
    post "/api/v1/notifications/read_all", headers: auth_headers(guest)

    expect(response).to have_http_status(:forbidden)
    expect(json["errors"]).to eq([ "Guests have read-only access" ])
  end

  it "still lets a guest manage their own API tokens" do
    post "/api/v1/api_tokens", params: { name: "laptop" }, headers: auth_headers(guest)
    expect(response).to have_http_status(:created)
  end

  # A guest may watch: start a session and report progress like anyone,
  # and a visitor (a guest from a paired household) the same.
  describe "watching" do
    let(:visitor) { create_user(household: household, role: "guest").tap { |u| u.update!(visitor_home: "01JHOMEINSTANCE0000000000Z") } }
    let(:movie) do
      root = build_root("Heat (1995)/Heat.mp4" => "h264_aac.mp4")
      library = create_library(household: household, roots: root)
      file = MediaFile.create!(household: household, library: library, path: File.join(root, "Heat (1995)/Heat.mp4"),
        size: File.size(media_fixture("h264_aac.mp4")), mtime: Time.current, state: "probed")
      Media::FileProber.new(file).call
      file.update!(duration_seconds: 3600)
      Movie.create!(household: household, library: library, title: "Heat", year: 1995).tap { |m| m.editions.create!(media_file: file) }
    end

    before { require_ffprobe! }

    [ :guest, :visitor ].each do |who|
      it "lets a #{who} start playback, report progress and end it" do
        person = public_send(who)
        post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: movie.id }, headers: auth_headers(person)
        expect(response).to have_http_status(:created)
        session_id = json["id"]
        post json["progress_url"], params: { position: 1800 }, as: :json
        expect(response).to have_http_status(:ok)
        expect(WatchState.sole.position_seconds).to eq(1800)

        post "/api/v1/playback_sessions/#{session_id}/standby", params: { position: 1800 }, headers: auth_headers(person)
        expect(response).to have_http_status(:no_content)
        post "/api/v1/playback_sessions/#{session_id}/watch", params: { position: 1800 }, headers: auth_headers(person)
        expect(response).to have_http_status(:no_content)
        delete "/api/v1/playback_sessions/#{session_id}", headers: auth_headers(person)
        expect(response).to have_http_status(:no_content)
        expect(PlaybackSession.find(session_id).state).to eq("ended")
      end
    end

    it "lets a guest touch only their own playback sessions" do
      member = create_user(household: household)
      post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: movie.id }, headers: auth_headers(member)
      theirs = json["id"]
      delete "/api/v1/playback_sessions/#{theirs}", headers: auth_headers(guest)
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/playback_sessions/#{theirs}/standby", headers: auth_headers(guest)
      expect(response).to have_http_status(:forbidden)
      expect(PlaybackSession.find(theirs).state).not_to eq("ended")
    end

    it "still refuses a guest's change to the library" do
      post "/api/v1/watch_later", params: { item_type: "movie", item_id: movie.id }, headers: auth_headers(guest)
      expect(response).to have_http_status(:forbidden)
      expect(json["errors"]).to eq([ "Guests have read-only access" ])
      post "/api/v1/watch_states", params: { playable_type: "movie", playable_id: movie.id, watched: true }, headers: auth_headers(guest)
      expect(response).to have_http_status(:forbidden)
      expect(WatchState.count).to eq(0)
    end
  end

  it "gives a member no such limit" do
    member = create_user(household: household)

    post "/api/v1/notifications/read_all", headers: auth_headers(member)

    expect(response).to have_http_status(:success)
  end
end

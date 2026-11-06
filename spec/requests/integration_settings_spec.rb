# typed: false
# frozen_string_literal: true

require "rails_helper"

# Settings › Integrations for Whisper, OpenSubtitles and Immich (CLAUDE.md,
# configuration belongs in the UI): entered in the app, stored encrypted,
# never sent back, and checked with a test that says what happened.
RSpec.describe "Integration settings", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:headers) { auth_headers(admin) }

  def raw(model, column) = model.class.connection.select_value("SELECT #{column} FROM #{model.class.table_name} WHERE id = '#{model.id}'")

  describe "Whisper" do
    it "saves the address and a write-only key, keeps the key when it's left blank, and forgets it all on delete" do
      get "/api/v1/whisper_setting", headers: headers
      expect(json).to eq("configured" => false)

      patch "/api/v1/whisper_setting", params: { whisper_setting: { url: "http://whisper.lan:9000/", api_kind: "asr_webservice",
        api_key: "whisper-secret", enabled: true } }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json).to include("configured" => true, "url" => "http://whisper.lan:9000", "api_key_set" => true)
      expect(response.body).not_to include("whisper-secret")
      setting = WhisperSetting.sole
      expect(setting.api_key).to eq("whisper-secret")
      expect(raw(setting, :api_key)).not_to include("whisper-secret")

      patch "/api/v1/whisper_setting", params: { whisper_setting: { model: "large-v3", api_key: "" } }, headers: headers, as: :json
      expect(setting.reload).to have_attributes(model: "large-v3", api_key: "whisper-secret")

      patch "/api/v1/whisper_setting", params: { whisper_setting: { url: "whisper.lan" } }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"]).to include(a_string_matching(/http/))

      delete "/api/v1/whisper_setting", headers: headers
      expect(json).to eq("configured" => false)
      expect(WhisperSetting.count).to eq(0)
    end

    it "tests the connection and keeps what it said" do
      post "/api/v1/whisper_setting/test", headers: headers
      expect(json).to eq("ok" => false, "message" => "Save Whisper's address first.")

      WhisperSetting.create!(household: household, url: "http://whisper.lan:9000", api_kind: "openai")
      stub_request(:get, "http://whisper.lan:9000/v1/models").to_return(status: 200, body: "{}")
      post "/api/v1/whisper_setting/test", headers: headers
      expect(json).to eq("ok" => true, "message" => "Whisper answered")

      stub_request(:get, "http://whisper.lan:9000/v1/models").to_return(status: 503, body: "warming up")
      post "/api/v1/whisper_setting/test", headers: headers
      expect(json["ok"]).to be(false)
      get "/api/v1/whisper_setting", headers: headers
      expect(json).to include("last_test_ok" => false, "last_test_message" => a_string_including("503"))
    end
  end

  describe "OpenSubtitles" do
    let(:api) { "https://api.opensubtitles.com/api/v1" }

    it "keeps the key and password write-only" do
      patch "/api/v1/open_subtitles_setting", params: { open_subtitles_setting: { api_key: "os-key", username: "ellie", password: "os-pass",
        languages: %w[en fr], enabled: true } }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json).to include("configured" => true, "username" => "ellie", "languages" => %w[en fr])
      expect(response.body).not_to include("os-key")
      expect(response.body).not_to include("os-pass")
      setting = OpenSubtitlesSetting.sole
      expect(raw(setting, :api_key)).not_to include("os-key")
      expect(raw(setting, :password)).not_to include("os-pass")

      patch "/api/v1/open_subtitles_setting", params: { open_subtitles_setting: { api_key: "", password: "", languages: %w[en] } },
        headers: headers, as: :json
      expect(setting.reload).to have_attributes(api_key: "os-key", password: "os-pass", languages: %w[en])

      get "/api/v1/open_subtitles_setting", headers: headers
      expect(response.body).not_to include("os-key")
    end

    it "asks for a key before anything else, and tests it" do
      patch "/api/v1/open_subtitles_setting", params: { open_subtitles_setting: { languages: %w[en] } }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)

      OpenSubtitlesSetting.create!(household: household, api_key: "os-key", languages: %w[en])
      stub_request(:get, "#{api}/infos/formats").with(headers: { "Api-Key" => "os-key" }).to_return(status: 200, body: "{}")
      post "/api/v1/open_subtitles_setting/test", headers: headers
      expect(json).to eq("ok" => true, "message" => "OpenSubtitles accepted the API key")

      stub_request(:get, "#{api}/infos/formats").to_return(status: 401, body: { message: "Invalid API key" }.to_json)
      post "/api/v1/open_subtitles_setting/test", headers: headers
      expect(json["ok"]).to be(false)
      expect(OpenSubtitlesSetting.sole.last_test_ok).to be(false)
    end
  end

  describe "MLB.tv" do
    it "keeps the password write-only, and tests the sign-in the way yt-dlp signs in" do
      patch "/api/v1/mlb_setting", params: { mlb_setting: { username: " fan@example.com ", password: "pa ss#\"word" } },
        headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json).to include("configured" => true, "username" => "fan@example.com")
      expect(response.body).not_to include("pa ss")
      setting = MlbSetting.sole
      expect(raw(setting, :password)).not_to include("pa ss")

      patch "/api/v1/mlb_setting", params: { mlb_setting: { username: "fan@example.com", password: "" } }, headers: headers, as: :json
      expect(setting.reload.password).to eq("pa ss#\"word")

      token = stub_request(:post, Mlb::Account::TOKEN_URL)
        .with(body: hash_including("grant_type" => "password", "username" => "fan@example.com", "password" => "pa ss#\"word",
          "client_id" => Mlb::Account::CLIENT_ID))
        .to_return(status: 200, body: { access_token: "jwt" }.to_json, headers: { "Content-Type" => "application/json" })
      post "/api/v1/mlb_setting/test", headers: headers
      expect(json).to eq("ok" => true, "message" => "Signed in to MLB.tv as fan@example.com")
      expect(token).to have_been_requested

      stub_request(:post, Mlb::Account::TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)
      post "/api/v1/mlb_setting/test", headers: headers
      expect(json).to eq("ok" => false, "message" => "MLB.tv didn't accept that email and password")
      expect(setting.reload.last_test_ok).to be(false)

      delete "/api/v1/mlb_setting", headers: headers
      expect(json).to eq("configured" => false)
      expect(MlbSetting.count).to eq(0)
    end

    it "is for admins" do
      get "/api/v1/mlb_setting", headers: auth_headers(create_user(household: household))
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "NBA League Pass" do
    it "turns on with nothing to fill in, tests that NBA's schedule can be read, and turns off" do
      post "/api/v1/nba_setting/test", headers: headers
      expect(json).to eq("ok" => false, "message" => "Turn on NBA League Pass first.")

      patch "/api/v1/nba_setting", params: { nba_setting: {} }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json).to include("configured" => true)
      expect(NbaSetting.count).to eq(1)

      allow(Nba::Schedule).to receive(:today).and_return(Date.new(2026, 10, 21))
      stub_request(:get, "#{Nba::Schedule::SCOREBOARD}?dates=20261021")
        .to_return(status: 200, body: { events: [] }.to_json, headers: { "Content-Type" => "application/json" })
      post "/api/v1/nba_setting/test", headers: headers
      expect(json).to eq("ok" => true, "message" => "Read NBA's schedule: no games today")
      expect(NbaSetting.sole.last_test_ok).to be(true)

      delete "/api/v1/nba_setting", headers: headers
      expect(json).to eq("configured" => false)
      expect(NbaSetting.count).to eq(0)
    end

    it "is for admins" do
      get "/api/v1/nba_setting", headers: auth_headers(create_user(household: household))
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "Immich" do
    let(:root) { build_root }

    it "saves a write-only key, tests it, and starts a sync only once it's set up" do
      post "/api/v1/immich_setting/sync", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"]).to eq([ "Set up Immich first" ])

      patch "/api/v1/immich_setting", params: { immich_setting: { url: "http://immich.lan:2283", api_key: "immich-secret",
        immich_path_prefix: "/usr/src/app/upload", local_path_prefix: root, enabled: true } }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      expect(json).to include("configured" => true, "local_path_prefix" => root)
      expect(response.body).not_to include("immich-secret")
      expect(raw(ImmichSetting.sole, :api_key)).not_to include("immich-secret")

      stub_request(:get, "http://immich.lan:2283/api/server/about").with(headers: { "x-api-key" => "immich-secret" })
        .to_return(status: 200, body: { version: "v1.120.0" }.to_json, headers: { "Content-Type" => "application/json" })
      post "/api/v1/immich_setting/test", headers: headers
      expect(json).to eq("ok" => true, "message" => "Connected to Immich v1.120.0")

      post "/api/v1/immich_setting/sync", headers: headers
      expect(response).to have_http_status(:accepted)
      expect(ImmichSyncJob).to have_been_enqueued.with(household.id)

      delete "/api/v1/immich_setting", headers: headers
      expect(ImmichSetting.count).to eq(0)
    end
  end

  # The rest of the household's secrets, as every settings read shows them.
  it "never sends back the TMDB, Trakt or Plex secrets, or a linked Trakt account's tokens" do
    TmdbSetting.create!(household: household, api_key: "tmdb-secret")
    TraktSetting.create!(household: household, client_id: "trakt-client", client_secret: "trakt-secret")
    TraktAccount.create!(household: household, profile: Profile.default_for(household), state: "linked", access_token: "trakt-access",
      refresh_token: "trakt-refresh", expires_at: 1.day.from_now)
    PlexConnection.create!(household: household, server_url: "http://plex.lan:32400", token: "plex-secret", machine_identifier: "m")

    %w[/api/v1/tmdb_setting /api/v1/trakt_setting /api/v1/trakt_account /api/v1/plex_connection /api/v1/app_setting /api/v1/me].each do |path|
      get path, headers: headers
      %w[tmdb-secret trakt-secret trakt-access trakt-refresh plex-secret].each do |secret|
        expect(response.body).not_to include(secret), "#{path} sent #{secret}"
      end
    end
  end
end

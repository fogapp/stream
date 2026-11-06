# typed: false
# frozen_string_literal: true

require "swagger_helper"

# What a native player needs, documented by running it (PROPOSAL §7.6).
RSpec.describe "Client API", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household, email: "watcher@example.com", password: "a long enough password") }
  let(:Authorization) { "Bearer #{ApiSession.generate!(user: user).token}" }
  let!(:profile) { Profile.default_for(household) }
  let(:"X-Stream-Profile") { ProfileTokens.issue(profile) }
  let(:library) { create_library(household: household, roots: build_root, name: "Movies") }
  let(:movie) do
    Movie.create!(household: household, library: library, title: "Heat", year: 1995).tap do |movie|
      file = MediaFile.create!(household: household, library: library, path: "/m/Heat.mkv", size: 1, mtime: Time.current, state: "probed")
      movie.editions.create!(media_file: file)
    end
  end

  path "/api/v1/session" do
    post "Sign in" do
      tags "Sign in"
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: { type: :object, properties: { email: { type: :string }, password: { type: :string },
                                                                                 device: { type: :string } }, required: %w[email password] }

      response "201", "signed in" do
        schema "$ref" => "#/components/schemas/Session"
        let(:body) { { email: user.email, password: "a long enough password", device: "Apple TV" } }
        run_test!
      end

      response "401", "wrong email or password" do
        schema "$ref" => "#/components/schemas/Errors"
        let(:body) { { email: user.email, password: "nope" } }
        run_test!
      end
    end
  end

  path "/api/v1/pairings" do
    post "Start pairing a TV: show the code, poll with the token" do
      tags "Sign in"
      produces "application/json"
      response "201", "a code to show" do
        schema "$ref" => "#/components/schemas/Pairing"
        run_test!
      end
    end
  end

  path "/api/v1/pairings/{poll_token}" do
    get "Poll a pairing: pending, or (once) the TV's session" do
      tags "Sign in"
      produces "application/json"
      parameter name: :poll_token, in: :path, type: :string
      response "200", "still waiting, or approved with token and user" do
        let(:poll_token) { DevicePairing.start!("TV").poll_token }
        schema type: :object, required: %w[state], properties: { state: { type: :string, enum: %w[pending approved] }, token: { type: :string },
                                                                 user: { "$ref" => "#/components/schemas/User" } }
        run_test!
      end
    end
  end

  path "/api/v1/profiles" do
    get "The household's profiles, for the picker" do
      tags "Profiles"
      security [ { bearerAuth: [] } ]
      produces "application/json"
      response "200", "profiles" do
        schema type: :array, items: { "$ref" => "#/components/schemas/Profile" }
        run_test!
      end
    end
  end

  path "/api/v1/profiles/current" do
    get "Who this device is watching as, and whether to show the picker" do
      tags "Profiles"
      security [ { bearerAuth: [], profileToken: [] } ]
      produces "application/json"
      response "200", "the current profile" do
        schema "$ref" => "#/components/schemas/CurrentProfile"
        run_test!
      end
    end
  end

  path "/api/v1/profiles/{id}/select" do
    post "Choose a profile (with its PIN): returns the X-Stream-Profile token" do
      tags "Profiles"
      security [ { bearerAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :id, in: :path, type: :string, format: :uuid
      parameter name: :body, in: :body, schema: { type: :object, properties: { pin: { type: :string }, make_default: { type: :boolean } } }

      response "200", "chosen" do
        schema type: :object, required: %w[token profile], properties: { token: { type: :string }, profile: { "$ref" => "#/components/schemas/Profile" } }
        let(:id) { profile.id }
        let(:body) { {} }
        run_test!
      end

      response "401", "wrong PIN" do
        schema "$ref" => "#/components/schemas/Errors"
        let(:id) { Profile.create!(household: household, name: "Locked", pin: "1234").id }
        let(:body) { { pin: "0000" } }
        run_test!
      end
    end
  end

  path "/api/v1/home" do
    get "Home: the hero and the hubs, in the profile's order" do
      tags "Browse"
      security [ { bearerAuth: [], profileToken: [] } ]
      produces "application/json"
      response "200", "home" do
        schema "$ref" => "#/components/schemas/Home"
        before { movie }
        run_test!
      end
    end
  end

  path "/api/v1/catalog_version" do
    get "Catalog version: changes when a file becomes playable, is replaced or goes missing; poll it to know when to refresh" do
      tags "Browse"
      security [ { bearerAuth: [], profileToken: [] } ]
      produces "application/json"
      response "200", "catalog version" do
        schema type: :object, required: %w[version], properties: { version: { type: :string, description: "Opaque; compare for change" } }
        before { movie }
        run_test!
      end
    end
  end

  path "/api/v1/movies" do
    get "A library's movies" do
      tags "Browse"
      security [ { bearerAuth: [], profileToken: [] } ]
      produces "application/json"
      parameter name: :library_id, in: :query, type: :string, required: false
      parameter name: :sort, in: :query, type: :string, enum: %w[title year added rating], required: false
      parameter name: :q, in: :query, type: :string, required: false
      parameter name: :tmdb_id, in: :query, type: :string, required: false,
        description: "Only these TMDB ids (comma-separated); OR'd with imdb_id"
      parameter name: :imdb_id, in: :query, type: :string, required: false,
        description: "Only these IMDb ids (comma-separated); OR'd with tmdb_id"
      response "200", "movies" do
        schema type: :array, items: { "$ref" => "#/components/schemas/MovieCard" }
        before { movie }
        run_test!
      end
    end
  end

  path "/api/v1/movies/letters" do
    get "Where each letter starts in a library's A–Z movies" do
      tags "Browse"
      security [ { bearerAuth: [], profileToken: [] } ]
      produces "application/json"
      parameter name: :library_id, in: :query, type: :string, required: false
      parameter name: :unwatched, in: :query, type: :boolean, required: false
      parameter name: :q, in: :query, type: :string, required: false
      response "200", "letters" do
        schema type: :array, items: { "$ref" => "#/components/schemas/LetterStart" }
        before { movie }
        run_test!
      end
    end
  end

  path "/api/v1/movies/{id}" do
    get "A movie: details, versions, cast, extras, where to resume" do
      tags "Browse"
      security [ { bearerAuth: [], profileToken: [] } ]
      produces "application/json"
      parameter name: :id, in: :path, type: :string, format: :uuid
      response "200", "the movie" do
        schema allOf: [ { "$ref" => "#/components/schemas/MovieCard" },
                        { type: :object, properties: { overview: { type: :string, nullable: true }, versions: { type: :array, items: { type: :object } },
                                                       resume_at: { type: :number, nullable: true } } } ]
        let(:id) { movie.id }
        run_test!
      end
      response "404", "not there, or not for this profile" do
        let(:id) { SecureRandom.uuid }
        run_test!
      end
    end
  end

  path "/api/v1/search" do
    get "Search titles, episodes, people, channels, videos, home videos, and what was said" do
      tags "Browse"
      security [ { bearerAuth: [], profileToken: [] } ]
      produces "application/json"
      parameter name: :q, in: :query, type: :string
      response "200", "results by kind" do
        schema type: :object, properties: { movies: { type: :array, items: { "$ref" => "#/components/schemas/MovieCard" } },
                                            shows: { type: :array, items: { "$ref" => "#/components/schemas/ShowCard" } },
                                            episodes: { type: :array, items: { "$ref" => "#/components/schemas/EpisodeCard" } },
                                            said: { type: :array, items: { type: :object } } }
        let(:q) { "heat" }
        before { movie }
        run_test!
      end
    end
  end

  path "/api/v1/playback_sessions" do
    post "Press Play: send what the device can decode, get where to play it from" do
      tags "Playback"
      security [ { bearerAuth: [], profileToken: [] } ]
      consumes "application/json"
      produces "application/json"
      description "The capability profile decides direct play, remux or transcode (PROPOSAL §6.1–6.2). " \
                  "`media_file_id` picks a version, `start` a position, `audio_index` a track, `playlist_id` a playlist to play through. " \
                  "A `live_stream` (PROPOSAL §7.8) is always relayed: its session's `live_stream` is set and its source is a live " \
                  "HLS playlist that opens at its newest; POST progress to keep it open."
      parameter name: :body, in: :body, schema: {
        type: :object, required: %w[playable_type playable_id],
        properties: {
          playable_type: { type: :string, enum: %w[movie episode video clip extra live_stream] }, playable_id: { type: :string, format: :uuid },
          capabilities: { type: :object, description: "hls (mse|native|none), video/audio codecs, containers, max_height" },
          device_key: { type: :string }, media_file_id: { type: :string }, start: { type: :number }, audio_index: { type: :integer },
          playlist_id: { type: :string },
          station_id: { type: :string, format: :uuid, description: "Grid: tune to what's on this channel now, where live is" },
          airing_id: { type: :string, format: :uuid, description: "Grid: one airing — its start (Restart), or the next as it begins" },
          standby: { type: :boolean, description: "Grid: tuned ahead for an instant channel change; not a play until POST …/watch" }
        }
      }

      response "201", "a session" do
        schema "$ref" => "#/components/schemas/PlaybackSession"
        let(:body) do
          require_ffprobe!
          root = build_root("Heat/Heat.mp4" => "h264_aac.mp4")
          path = File.join(root, "Heat/Heat.mp4")
          file = MediaFile.create!(household: household, library: create_library(household: household, roots: root), path: path,
            size: File.size(path), mtime: Time.current, state: "discovered")
          Media::FileProber.new(file).call
          heat = Movie.create!(household: household, library: file.library, title: "Heat", year: 1995).tap { |m| m.editions.create!(media_file: file) }
          { playable_type: "movie", playable_id: heat.id,
            capabilities: { hls: "native", video: %w[h264 hevc], audio: %w[aac ac3], containers: %w[mp4] } }
        end
        run_test!
      end
    end
  end

  path "/api/v1/playback_sessions/{id}/fallback" do
    post "A play that failed: carry it on a rung down the ladder, from where it got to" do
      tags "Playback"
      security [ { bearerAuth: [], profileToken: [] } ]
      consumes "application/json"
      produces "application/json"
      description "The failed session ends with why; the answer is a new session a rung down " \
                  "(direct → remux → audio converted → video converted → in software), starting at `position`. Asked twice, it " \
                  "answers with the same session. 409 when there's no rung left, saying what was tried."
      parameter name: :id, in: :path, type: :string
      parameter name: :body, in: :body, schema: {
        type: :object, required: %w[failure_class],
        properties: {
          failure_class: { type: :string, enum: PlaybackSession::FailureClass.values.map(&:serialize),
                           description: "decode: couldn't decode it; unsupported: wouldn't open it; stalled; network; server: a 424" },
          cause: { type: :string, description: "The player's own words, for the Playback page" }, position: { type: :number }
        }
      }

      response "201", "the play, carried on" do
        schema "$ref" => "#/components/schemas/PlaybackSession"
        let(:id) do
          require_ffprobe!
          root = build_root("Heat/Heat.mp4" => "h264_aac.mp4")
          path = File.join(root, "Heat/Heat.mp4")
          file = MediaFile.create!(household: household, library: create_library(household: household, roots: root), path: path,
            size: File.size(path), mtime: Time.current, state: "discovered")
          Media::FileProber.new(file).call
          heat = Movie.create!(household: household, library: file.library, title: "Heat", year: 1995).tap { |m| m.editions.create!(media_file: file) }
          decision = Playback::Decision.new(file.reload, Playback::Capabilities.from_json("hls" => "native", "video" => %w[h264], "audio" => %w[aac],
            "containers" => %w[mp4]))
          PlaybackSession.create!(household: household, profile: profile, user: user, playable: heat, media_file: file, method: decision.method.serialize,
            decision: decision.to_h, started_at: Time.current, last_seen_at: Time.current).id
        end
        let(:body) { { failure_class: "decode", cause: "AVFoundationErrorDomain -11821", position: 1.0 } }
        before { allow(Playback::Signal).to receive(:request) }
        run_test!
      end
    end
  end

  path "/api/v1/playback_sessions/{id}/upgrade" do
    post "A play that fell back for a passing reason: climb back to the rung it fell from, if there's a better one" do
      tags "Playback"
      security [ { bearerAuth: [], profileToken: [] } ]
      consumes "application/json"
      produces "application/json"
      description "For a session whose `fallback.upgradable` is true, at a natural break (a seek). 201 with the new session; 204 " \
                  "when there's nothing better. If the climb fails too, POST …/fallback returns to the rung that worked."
      parameter name: :id, in: :path, type: :string
      parameter name: :body, in: :body, schema: { type: :object, properties: { position: { type: :number } } }

      response "204", "nothing better" do
        let(:id) do
          library = create_library(household: household, roots: build_root)
          heat = Movie.create!(household: household, library: library, title: "Heat", year: 1995)
          PlaybackSession.create!(household: household, profile: profile, user: user, playable: heat, method: "direct", started_at: Time.current,
            last_seen_at: Time.current).id
        end
        let(:body) { { position: 30.0 } }
        run_test!
      end
    end
  end
end

# Cameras and web streams (PROPOSAL §7.8): pressed play on like a title,
# relayed live by Stream.
RSpec.describe "Client API: Live streams", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:Authorization) { "Bearer #{ApiSession.generate!(user: user).token}" }
  let!(:profile) { Profile.default_for(household) }
  let(:"X-Stream-Profile") { ProfileTokens.issue(profile) }
  let(:library) { Library.create!(household: household, name: "Cameras", kind: "live") }
  let(:stream) do
    LiveStream.create!(household: household, library: library, name: "Front door", kind: "camera",
      url: "rtsps://192.168.1.1:7441/AbCdEfGhIjKlMnOp?enableSrtp").tap do |live|
      live.media_streams.create!(index: 0, kind: "audio", codec: "aac", channels: 1)
      live.media_streams.create!(index: 1, kind: "video", codec: "h264", bit_depth: 8, height: 2160)
    end
  end

  path "/api/v1/live_streams" do
    get "The profile's cameras and web streams, in a library or all" do
      tags "Live streams"
      security [ { bearerAuth: [], profileToken: [] } ]
      produces "application/json"
      description "Play one with POST /api/v1/playback_sessions { playable_type: live_stream, playable_id }."
      parameter name: :library_id, in: :query, type: :string, required: false
      response "200", "streams, by name" do
        schema type: :array, items: { "$ref" => "#/components/schemas/LiveStream" }
        let(:library_id) { library.id }
        before { stream }
        run_test!
      end
    end
  end
end

# Grid (PROPOSAL §7.7): channels made from the library on a schedule.
RSpec.describe "Client API: Grid", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:Authorization) { "Bearer #{ApiSession.generate!(user: user).token}" }
  let!(:profile) { Profile.default_for(household) }
  let(:"X-Stream-Profile") { ProfileTokens.issue(profile) }
  let(:station) { Station.create!(household: household, number: "4", name: "NBC") }
  let(:airing) do
    library = create_library(household: household, roots: build_root, kind: "shows", name: "TV")
    show = Show.create!(household: household, library: library, folder: "Office", title: "The Office")
    file = MediaFile.create!(household: household, library: library, path: "/tv/1.mkv", size: 1, mtime: Time.current, state: "probed",
      duration_seconds: 1320)
    episode = show.episodes.create!(season: show.seasons.create!(season_number: 1), season_number: 1, episode_number: 1, title: "Pilot")
    episode.editions.create!(media_file: file)
    Airing.create!(household: household, station: station, playable: episode, media_file: file, series_key: show.id,
      starts_at: 1.hour.from_now, ends_at: 1.hour.from_now + 22.minutes, reason: "The channel's mix · next in order")
  end

  path "/api/v1/guide" do
    get "The guide: the profile's channels and their airings between two times" do
      tags "Grid"
      security [ { bearerAuth: [], profileToken: [] } ]
      produces "application/json"
      description "Defaults to half an hour ago until three hours ahead; at most 26 hours at once. Filler (between programs) is flagged."
      parameter name: :from, in: :query, type: :string, format: "date-time", required: false
      parameter name: :to, in: :query, type: :string, format: "date-time", required: false
      response "200", "channels in number order, with what's on each" do
        schema "$ref" => "#/components/schemas/Guide"
        let(:to) { 3.hours.from_now.iso8601 }
        before { airing }
        run_test!
      end
    end
  end

  path "/api/v1/stations" do
    get "The profile's channels (hidden=1 includes the ones it hid)" do
      tags "Grid"
      security [ { bearerAuth: [], profileToken: [] } ]
      produces "application/json"
      parameter name: :hidden, in: :query, type: :boolean, required: false
      response "200", "channels" do
        schema type: :array, items: { "$ref" => "#/components/schemas/Station" }
        before { station }
        run_test!
      end
    end
  end

  path "/api/v1/playback_sessions/{id}/watch" do
    post "Switch to a channel tuned ahead on standby: from now it's a play" do
      tags "Grid"
      security [ { bearerAuth: [], profileToken: [] } ]
      consumes "application/json"
      parameter name: :id, in: :path, type: :string
      parameter name: :body, in: :body, schema: { type: :object, properties: { position: { type: :number } } }
      response "204", "watching" do
        let(:id) do
          PlaybackSession.create!(household: household, profile: profile, user: user, playable: airing.playable, media_file: airing.media_file,
            airing: airing, standby: true, method: "direct", started_at: Time.current, last_seen_at: Time.current).id
        end
        let(:body) { { position: 12.0 } }
        run_test!
      end
    end
  end

  path "/api/v1/stations/{id}/favorite" do
    put "Keep a channel among the profile's favourites (DELETE to stop)" do
      tags "Grid"
      security [ { bearerAuth: [], profileToken: [] } ]
      parameter name: :id, in: :path, type: :string
      response "204", "a favourite" do
        let(:id) { station.id }
        run_test!
      end
    end
  end

  path "/api/v1/airings/{id}/reminder" do
    put "Be reminded two minutes before a program starts (DELETE to forget)" do
      tags "Grid"
      security [ { bearerAuth: [], profileToken: [] } ]
      parameter name: :id, in: :path, type: :string
      response "204", "reminded" do
        let(:id) { airing.id }
        run_test!
      end
    end
  end
end

RSpec.describe "The OpenAPI document", type: :request do
  it "is served at /api-docs for a client generator" do
    get "/api-docs/v1/openapi.yaml"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("title: Stream API", "/api/v1/playback_sessions")
  end
end

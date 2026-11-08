# typed: false
# frozen_string_literal: true

require "rails_helper"

# One household never reaches another's rows. Next door is a whole household
# of its own — every title carries the word "Zanzibar" — and this household's
# admin, the most anyone here can be, aims every id-taking endpoint at it.
# Each attempt must be refused, must not echo next door's data, and must not
# change a row anywhere.
#
# The first half walks the route table itself, so a new route that takes an
# id fails here until it's mapped below; the second covers the endpoints that
# take a foreign id in the body.
RSpec.describe "Tenancy", type: :request do
  MARKER = "Zanzibar"

  # Server-wide or authenticated by something other than a login, with why.
  EXEMPT = {
    "api/v1/background_jobs#run" => "server-wide jobs, admin-only (background_jobs_spec)",
    "api/v1/transcode_nodes" => "transcoders serve the whole server (transcode_nodes_spec)",
    "api/v1/transcoder" => "a node's own token, not a login (transcode_nodes_spec)",
    "api/v1/pairings#show" => "a TV polls with the secret it was given, signed in to nothing (pairings_spec)",
    "api/v1/baseball#watch" => "the id is MLB's game number, not a row; the stream is the household's own (baseball_spec)",
    "api/v1/hook_requests#want_show" => "the id is Hook's show, not a row; Hook scopes it (hook_requests_spec)"
  }.freeze

  # Shared by every household, so a 200 is right — but only with this
  # household's titles in it.
  ANSWERS_WITHOUT_LEAKING = %w[api/v1/people#show api/v1/activity#trace].freeze

  # The admin surface, written down: dropping a guard, or adding an admin
  # route, shows up here as a change someone reviews.
  ADMIN_SURFACE = <<~ROUTES.lines(chomp: true).freeze
    DELETE /api/v1/arr_webhook/path_mappings/:mapping_id
    DELETE /api/v1/artwork_choices/reset
    DELETE /api/v1/collections/:id
    DELETE /api/v1/collections/:id/items
    DELETE /api/v1/immich_setting
    DELETE /api/v1/libraries/:id
    DELETE /api/v1/live_streams/:id
    DELETE /api/v1/media_files/:id/markers/:kind
    DELETE /api/v1/mlb_setting
    DELETE /api/v1/nba_setting
    DELETE /api/v1/open_subtitles_setting
    DELETE /api/v1/optimized_versions/:id
    DELETE /api/v1/plex_connection
    DELETE /api/v1/profiles/:id
    DELETE /api/v1/stations/:id
    DELETE /api/v1/tmdb_setting
    DELETE /api/v1/trakt_setting
    DELETE /api/v1/transcode_nodes/:id
    DELETE /api/v1/whisper_setting
    GET /api/v1/arr_webhook
    GET /api/v1/artwork_choices
    GET /api/v1/background_jobs
    GET /api/v1/channels/:channel_id/tracking
    GET /api/v1/immich_setting
    GET /api/v1/libraries/fog_suggestions
    GET /api/v1/mlb_setting
    GET /api/v1/nba_setting
    GET /api/v1/open_subtitles_setting
    GET /api/v1/optimized_versions
    GET /api/v1/optimized_versions/status
    GET /api/v1/playback_decisions
    GET /api/v1/playback_decisions/:id
    GET /api/v1/playback_lessons
    DELETE /api/v1/playback_lessons/:id
    GET /api/v1/playback_decisions/facets
    GET /api/v1/playback_decisions/health
    GET /api/v1/playback_decisions/summary
    GET /api/v1/playback_decisions/transcode_report
    GET /api/v1/plex_connection
    GET /api/v1/plex_imports
    GET /api/v1/profile_tags
    GET /api/v1/shows/:id/info
    GET /api/v1/shows/:id/progress
    GET /api/v1/stations/:id
    GET /api/v1/stations/options
    GET /api/v1/stations/preset
    GET /api/v1/stats/history
    GET /api/v1/stats/now_playing
    GET /api/v1/stats/summary
    GET /api/v1/trakt_setting
    GET /api/v1/transcode_nodes
    GET /api/v1/whisper_setting
    GET /api/v1/youtube
    PATCH /api/v1/app_setting
    PATCH /api/v1/channels/:channel_id/tracking
    PATCH /api/v1/channels/:channel_id/tracking/downloads/:download_id
    PATCH /api/v1/collections/:id
    PATCH /api/v1/immich_setting
    PATCH /api/v1/libraries/:id
    PATCH /api/v1/live_streams/:id
    PATCH /api/v1/metadata/:kind/:id
    PATCH /api/v1/mlb_setting
    PATCH /api/v1/nba_setting
    PATCH /api/v1/open_subtitles_setting
    PATCH /api/v1/plex_connection
    PATCH /api/v1/plex_connection/users/:mapping_id
    PATCH /api/v1/profile_tags
    PATCH /api/v1/stations/:id
    PATCH /api/v1/tmdb_setting
    PATCH /api/v1/trakt_setting
    PATCH /api/v1/transcode_nodes/:id
    PATCH /api/v1/whisper_setting
    PATCH /api/v1/youtube
    PATCH /api/v1/youtube/sponsorblock
    PATCH /api/v1/youtube/end_screen
    POST /api/v1/arr_webhook/path_mappings
    POST /api/v1/arr_webhook/regenerate
    POST /api/v1/artwork_choices/upload
    POST /api/v1/background_jobs/:key/run
    POST /api/v1/channels/:channel_id/tracking/downloads/:download_id/retry
    POST /api/v1/channels/:channel_id/tracking/link
    POST /api/v1/channels/:channel_id/tracking/poll
    POST /api/v1/collections
    POST /api/v1/collections/:id/items
    POST /api/v1/hook/test
    POST /api/v1/immich_setting/sync
    POST /api/v1/immich_setting/test
    POST /api/v1/invites
    POST /api/v1/libraries
    POST /api/v1/libraries/:id/rematch
    POST /api/v1/libraries/:id/scan
    POST /api/v1/libraries/validate_path
    POST /api/v1/live_streams
    POST /api/v1/live_streams/:id/probe
    POST /api/v1/live_streams/test
    POST /api/v1/matches/:kind/:id
    POST /api/v1/matches/:kind/:id/search
    POST /api/v1/matches/show/:id/reject
    POST /api/v1/media_files/:id/rerun
    POST /api/v1/metadata/:kind/:id/refresh
    POST /api/v1/mlb_setting/test
    POST /api/v1/nba_setting/test
    POST /api/v1/open_subtitles_setting/test
    POST /api/v1/optimized_versions
    POST /api/v1/optimized_versions/bulk
    POST /api/v1/optimized_versions/scan
    POST /api/v1/plex_connection/test
    POST /api/v1/plex_imports
    POST /api/v1/profiles
    POST /api/v1/stations
    POST /api/v1/stations/preview
    POST /api/v1/tmdb_setting/test
    POST /api/v1/trakt_setting/test
    POST /api/v1/transcode_nodes
    POST /api/v1/videos/:id/identify
    POST /api/v1/videos/:id/not_on_youtube
    POST /api/v1/whisper_setting/test
    POST /api/v1/youtube/resolve
    POST /api/v1/youtube/track
    POST /api/v1/youtube/update_tool
    PUT /api/v1/app_setting
    PUT /api/v1/artwork_choices/choose
    PUT /api/v1/channels/:channel_id/tracking
    PUT /api/v1/collections/:id
    PUT /api/v1/collections/:id/order
    PUT /api/v1/immich_setting
    PUT /api/v1/libraries/:id
    PUT /api/v1/live_streams/:id
    PUT /api/v1/media_files/:id/markers/:kind
    PUT /api/v1/mlb_setting
    PUT /api/v1/nba_setting
    PUT /api/v1/open_subtitles_setting
    PUT /api/v1/plex_connection
    PUT /api/v1/profile_tags
    PUT /api/v1/stations/:id
    PUT /api/v1/tmdb_setting
    PUT /api/v1/trakt_setting
    PUT /api/v1/transcode_nodes/:id
    PUT /api/v1/whisper_setting
    PUT /api/v1/youtube
  ROUTES

  # Refused to a kid profile outright (require_grown_up!).
  GROWN_UPS_ONLY = %w[api/v1/activity#index api/v1/matches#folders api/v1/matches#index api/v1/media_files#index
                      api/v1/media_files#show].freeze

  # Rows a refused request may still touch: the caller's own session and
  # device, and the timeline.
  NOISY_TABLES = %w[api_sessions devices activity_entries ar_internal_metadata schema_migrations].freeze

  let(:household) { create_household(name: "Here") }
  let(:admin) { create_user(household: household, role: "admin") }
  let!(:headers) { auth_headers(admin) }
  let!(:mine) { Profile.default_for(household) }
  let!(:theirs) { world_for(create_household(name: "#{MARKER} House")) }

  # A household with one of everything, every title marked.
  def world_for(other)
    them = create_user(household: other, role: "admin", email: "#{other.id}@example.com")
    profile = Profile.default_for(other)
    films = create_library(household: other, roots: build_root, name: "#{MARKER} Films")
    tv = create_library(household: other, roots: build_root, kind: "shows", name: "#{MARKER} TV")
    tube = create_library(household: other, roots: build_root, kind: "channels", name: "#{MARKER} Tube")
    home = create_library(household: other, roots: build_root, kind: "home_videos", name: "#{MARKER} Home")
    file = ->(library, name) {
      MediaFile.create!(household: other, library: library, path: "#{library.roots.first}/#{name}.mkv", size: 1, mtime: Time.current,
        state: "probed", duration_seconds: 3000)
    }

    movie = Movie.create!(household: other, library: films, title: "#{MARKER} Heat", year: 1995)
    movie_file = file.call(films, "heat")
    movie.editions.create!(media_file: movie_file)
    person = Person.create!(name: "#{MARKER} Pacino", tmdb_id: rand(900_000..999_999))
    Credit.create!(person: person, creditable: movie, role: "cast", character: "#{MARKER} Hanna")

    show = Show.create!(household: other, library: tv, folder: "Nights", title: "#{MARKER} Nights")
    season = show.seasons.create!(season_number: 1)
    episode = show.episodes.create!(season: season, season_number: 1, episode_number: 1, title: "#{MARKER} Pilot")
    episode.editions.create!(media_file: file.call(tv, "pilot"))

    channel = Channel.create!(household: other, library: tube, folder: "Z", title: "#{MARKER} Channel")
    video = Video.create!(household: other, library: tube, channel: channel, title: "#{MARKER} Video", upload_date: Date.current,
      source: "folder", youtube_id: SecureRandom.alphanumeric(11))
    video.editions.create!(media_file: file.call(tube, "video"))
    download = YoutubeDownload.create!(household: other, channel: channel, youtube_id: SecureRandom.alphanumeric(11), title: "#{MARKER} Download")

    clip = Clip.create!(household: other, library: home, title: "#{MARKER} Beach", sort_title: "beach", captured_at: Time.current,
      captured_source: "immich")
    clip.editions.create!(media_file: file.call(home, "beach"))
    album = Album.create!(household: other, title: "#{MARKER} Summer", immich_id: SecureRandom.hex(4))
    cameras = Library.create!(household: other, name: "#{MARKER} Cameras", kind: "live")
    live_stream = LiveStream.create!(household: other, library: cameras, name: "#{MARKER} Door", kind: "camera",
      url: "rtsps://192.0.2.1:7441/zanzibartoken?enableSrtp")

    playlist = Playlist.create!(household: other, profile: profile, title: "#{MARKER} List")
    PlaylistItem.create!(playlist: playlist, item: movie, position: 1)
    collection = Collection.create!(household: other, title: "#{MARKER} Collection", kind: "manual")
    station = Station.create!(household: other, number: "9", name: "#{MARKER} Nine")
    airing = Airing.create!(household: other, station: station, playable: episode, media_file: episode.media_files.first,
      series_key: show.id, starts_at: 10.minutes.ago, ends_at: 40.minutes.from_now, reason: "Test")
    device = Device.create!(household: other, client_key: SecureRandom.hex(4), name: "#{MARKER} TV", remote_control: true,
      remote_seen_at: Time.current, last_seen_at: Time.current)
    session = PlaybackSession.create!(household: other, profile: profile, playable: movie, media_file: movie_file, method: "direct",
      decision: {}, started_at: Time.current, last_seen_at: Time.current)
    lesson = Playability.create!(household: other, media_file: movie_file, format_signature: "#{MARKER}", client_class: "#{MARKER} Chrome",
      rung: "direct", failures: 1, last_failed_at: Time.current, last_failure_cause: "#{MARKER} failed")
    offline = OfflineDownload.create!(household: other, profile: profile, playable: movie, media_file: movie_file, size: 1,
      expires_at: 1.day.from_now)
    version = OptimizedVersion.create!(household: other, media_file: movie_file, state: "failed", attempts: 3, error: "#{MARKER} failed")
    notification = Notification.create!(user: them, household: other, kind: "k", title: "#{MARKER} news", dedupe_key: SecureRandom.hex(4))
    token = ApiToken.generate(user: them, name: "#{MARKER} token")
    credential = them.webauthn_credentials.create!(external_id: SecureRandom.hex(8), public_key: "pk", nickname: "#{MARKER} key")
    node = TranscodeNode.create!(name: "#{MARKER} Mac", token_digest: SecureRandom.hex, token_prefix: "zz")
    mapping = PathMapping.create!(household: other, remote_prefix: "/zanzibar", local_prefix: films.roots.first)
    plex = PlexConnection.create!(household: other, server_url: "http://plex.zanzibar:32400", token: "zt", machine_identifier: "z")
    plex_user = PlexUserMapping.create!(plex_connection: plex, plex_user_id: "9", plex_name: "#{MARKER} Plex", profile: profile)
    trace = SecureRandom.uuid
    Current.set(trace_id: trace) do
      Activity.record(source: "system", event: "secret", summary: "#{MARKER} happened", household_id: other.id)
    end

    { household: other, user: them, profile: profile, library: films, movie: movie, media_file: movie_file, person: person,
      show: show, episode: episode, channel: channel, video: video, download: download, clip: clip, album: album,
      playlist: playlist, collection: collection, station: station, airing: airing, device: device, session: session,
      offline: offline, version: version, notification: notification, token: token.api_token, credential: credential,
      mapping: mapping, plex_user: plex_user, trace: trace, node: node, live_stream: live_stream, lesson: lesson }
  end

  def path_param(world, controller, name)
    case [ controller, name ]
    in [ _, "channel_id" ] then world[:channel].id
    in [ _, "download_id" ] then world[:download].id
    in [ _, "season_number" ] then "1"
    in [ _, "trace_id" ] then world[:trace]
    in [ _, "profile_id" ] then world[:profile].id
    in [ _, "key" ] then "prune_operational_data"
    in [ "api/v1/arr_webhooks", "mapping_id" ] then world[:mapping].id
    in [ "api/v1/plex_connections", "mapping_id" ] then world[:plex_user].id
    in [ "api/v1/matches" | "api/v1/metadata", "kind" ] then "movie"
    in [ "api/v1/media_files", "kind" ] then "intro"
    in [ "api/v1/transcode_nodes", "id" ] then world[:node].id
    in [ _, "id" ] then world.fetch(ID_OWNERS.fetch(controller)).id
    end
  end

  def fill(path, world, controller) = path.gsub(/:(\w+)/) { path_param(world, controller, Regexp.last_match(1)) }

  ID_OWNERS = {
    "api/v1/airings" => :airing, "api/v1/api_tokens" => :token, "api/v1/channels" => :channel, "api/v1/clips" => :clip,
    "api/v1/collections" => :collection, "api/v1/episodes" => :episode, "api/v1/libraries" => :library, "api/v1/live_streams" => :live_stream, "api/v1/matches" => :movie,
    "api/v1/media_files" => :media_file, "api/v1/metadata" => :movie, "api/v1/movies" => :movie,
    "api/v1/notifications" => :notification, "api/v1/offline_downloads" => :offline, "api/v1/optimized_versions" => :version,
    "api/v1/people" => :person, "api/v1/playback_decisions" => :session, "api/v1/playback_lessons" => :lesson, "api/v1/playback_sessions" => :session, "api/v1/playlists" => :playlist,
    "api/v1/profiles" => :profile, "api/v1/remote" => :device, "api/v1/shows" => :show, "api/v1/stations" => :station,
    "api/v1/videos" => :video, "api/v1/webauthn_credentials" => :credential
  }.freeze

  def api_routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      next unless path.start_with?("/api/v1/")

      [ route.verb, path, *route.defaults.values_at(:controller, :action) ]
    end.uniq
  end

  def routes_taking_ids
    api_routes.select do |_, path, controller, action|
      path.include?(":") && !EXEMPT.key?("#{controller}##{action}") && !EXEMPT.key?(controller)
    end
  end

  def controllers
    @controllers ||= begin
      Rails.application.eager_load!
      ActionController::API.descendants.index_by(&:controller_path)
    end
  end

  # Where require_admin! guards the action, read from the controller's own
  # before_action (only:/except: included), so a new admin route is here too.
  def admin_only?(controller, action)
    callback = controllers[controller]&._process_action_callbacks&.find { |candidate| candidate.filter == :require_admin! }
    return false if callback.nil?

    # only: lands in its @if, except: in its @unless — and so does a
    # skip_before_action's only: (a subclass letting one action through).
    # Each names actions; the callback runs when every @if names this one
    # and no @unless does.
    names = ->(condition) { condition.instance_variable_get(:@actions).include?(action) }
    Array(callback.instance_variable_get(:@if)).all?(&names) && Array(callback.instance_variable_get(:@unless)).none?(&names)
  end

  def world_digest
    connection = ActiveRecord::Base.connection
    (connection.tables - NOISY_TABLES).sort.to_h do |table|
      [ table, connection.select_value("SELECT md5(coalesce(string_agg(t::text, '|' ORDER BY t::text), '')) FROM #{connection.quote_table_name(table)} t") ]
    end
  end

  def changed_tables(before) = world_digest.reject { |table, digest| before[table] == digest }.keys

  def attempt(verb, path, params = {})
    send(verb.downcase, path, params: params, headers: headers, as: :json)
  end

  it "refuses every path id from next door, with nothing said and nothing changed" do
    before = world_digest
    failures = []

    routes_taking_ids.each do |verb, path, controller, action|
      url = fill(path, theirs, controller)
      attempt(verb, url)
      label = "#{verb} #{path} (#{controller}##{action})"
      shared = ANSWERS_WITHOUT_LEAKING.include?("#{controller}##{action}")
      failures << "#{label} answered #{response.status}" if response.successful? && !shared
      failures << "#{label} echoed next door's data" if response.body.include?(MARKER)
      failures << "#{label} changed #{changed_tables(before).join(', ')}" if changed_tables(before).any?
      before = world_digest
    end

    expect(failures).to be_empty, failures.join("\n")
  end

  it "refuses next door's ids in a request's body" do
    my_playlist = Playlist.create!(household: household, profile: mine, title: "Mine")
    my_collection = Collection.create!(household: household, title: "Mine", kind: "manual")
    my_screen = Device.create!(household: household, client_key: "here-tv", name: "TV", remote_control: true,
      remote_seen_at: Time.current, last_seen_at: Time.current)
    kid = Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 7)
    movie = theirs[:movie]
    episode = theirs[:episode]
    attempts = [
      [ "POST", "/api/v1/playback_sessions", { playable_type: "movie", playable_id: movie.id } ],
      [ "POST", "/api/v1/playback_sessions", { playable_type: "episode", playable_id: episode.id } ],
      [ "POST", "/api/v1/playback_sessions", { playable_type: "movie", playable_id: movie.id, media_file_id: theirs[:media_file].id } ],
      [ "POST", "/api/v1/playback_sessions", { station_id: theirs[:station].id } ],
      [ "POST", "/api/v1/playback_sessions", { airing_id: theirs[:airing].id } ],
      [ "POST", "/api/v1/playback_sessions", { playable_type: "movie", playable_id: movie.id, playlist_id: theirs[:playlist].id } ],
      [ "POST", "/api/v1/offline_downloads", { playable_type: "movie", playable_id: movie.id } ],
      [ "POST", "/api/v1/optimized_versions", { media_file_id: theirs[:media_file].id } ],
      [ "POST", "/api/v1/optimized_versions/bulk", { bulk_action: "skip", media_file_ids: [ theirs[:media_file].id ] } ],
      [ "GET", "/api/v1/optimized_versions", { q: MARKER } ],
      [ "POST", "/api/v1/watch_states", { playable_type: "episode", playable_id: episode.id, watched: true } ],
      [ "POST", "/api/v1/watch_states", { playable_type: "movie", playable_id: movie.id, watched: true } ],
      [ "POST", "/api/v1/watch_states/hide", { playable_type: "movie", playable_id: movie.id } ],
      [ "PUT", "/api/v1/rating", { rateable_type: "movie", rateable_id: movie.id, value: 9 } ],
      [ "PUT", "/api/v1/rating", { rateable_type: "episode", rateable_id: episode.id, value: 9 } ],
      [ "PUT", "/api/v1/rating", { rateable_type: "show", rateable_id: theirs[:show].id, value: 9 } ],
      [ "POST", "/api/v1/playlists/#{my_playlist.id}/items", { item_type: "movie", item_id: movie.id } ],
      [ "POST", "/api/v1/collections/#{my_collection.id}/items", { item_type: "movie", item_id: movie.id } ],
      [ "POST", "/api/v1/watch_later", { item_type: "episode", item_id: episode.id } ],
      [ "DELETE", "/api/v1/watch_later", { item_type: "movie", item_id: movie.id } ],
      [ "DELETE", "/api/v1/playlists/#{my_playlist.id}/items", { item_type: "movie", item_id: movie.id } ],
      [ "PUT", "/api/v1/profile_tags", { profile_id: theirs[:profile].id, taggable_type: "Movie", taggable_id: movie.id, tagged: true } ],
      [ "PUT", "/api/v1/profile_tags", { profile_id: kid.id, taggable_type: "Movie", taggable_id: movie.id, tagged: true } ],
      [ "GET", "/api/v1/profile_tags", { profile_id: theirs[:profile].id } ],
      [ "POST", "/api/v1/remote/devices/#{my_screen.id}/commands", { kind: "play", playable_type: "movie", playable_id: movie.id } ],
      [ "POST", "/api/v1/remote/devices/#{my_screen.id}/commands", { kind: "play", playable_type: "episode", playable_id: episode.id } ],
      [ "GET", "/api/v1/transcript", { playable_type: "movie", playable_id: movie.id } ],
      [ "GET", "/api/v1/artwork_choices", { owner_type: "movie", owner_id: movie.id, kind: "poster" } ],
      [ "PUT", "/api/v1/artwork_choices/choose", { owner_type: "movie", owner_id: movie.id, kind: "poster", path: "/x.jpg" } ],
      [ "GET", "/api/v1/stats/history", { profile_id: theirs[:profile].id } ],
      [ "GET", "/api/v1/playback_decisions", { profile_id: theirs[:profile].id } ],
      [ "GET", "/api/v1/movies", { library_id: theirs[:library].id } ],
      [ "GET", "/api/v1/shows", { library_id: theirs[:library].id } ],
      [ "GET", "/api/v1/channels", { library_id: theirs[:library].id } ],
      [ "GET", "/api/v1/clips", { album_id: theirs[:album].id } ],
      [ "GET", "/api/v1/media_files", { library_id: theirs[:library].id } ],
      [ "GET", "/api/v1/search", { q: MARKER } ],
      [ "GET", "/api/v1/playlists", {} ],
      [ "GET", "/api/v1/collections", {} ],
      [ "GET", "/api/v1/stations", {} ],
      [ "GET", "/api/v1/notifications", {} ],
      [ "GET", "/api/v1/remote/devices", {} ],
      [ "GET", "/api/v1/stats/now_playing", {} ],
      [ "GET", "/api/v1/home", {} ]
    ]
    before = world_digest
    failures = []

    attempts.each do |verb, path, params|
      # A made-up route would 404 and look like a refusal.
      expect { Rails.application.routes.recognize_path(path, method: verb) }.not_to raise_error, "#{verb} #{path} isn't a route"
      attempt(verb, path, params)
      label = "#{verb} #{path} #{params.keys.join(',')}"
      failures << "#{label} echoed next door's data" if response.body.include?(MARKER)
      failures << "#{label} changed #{changed_tables(before).join(', ')}" if changed_tables(before).any?
      # Reads may answer (with none of next door in them), and removing
      # something from one's own list that was never there changes nothing.
      failures << "#{label} answered #{response.status}" if %w[GET DELETE].exclude?(verb) && response.successful?
      before = world_digest
    end

    expect(failures).to be_empty, failures.join("\n")
  end

  it "keeps every admin route to admins, and never to a kid profile" do
    ours = world_for(household)
    member = auth_headers(create_user(household: household))
    kid = profile_header(Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 7))
    guarded = api_routes.select { |_, _, controller, action| admin_only?(controller, action) }
    expect(guarded.map { |verb, path, _, _| "#{verb} #{path}" }).to match_array(ADMIN_SURFACE)
    before = world_digest
    failures = []

    guarded.each do |verb, path, controller, action|
      url = fill(path, ours, controller)
      label = "#{verb} #{path} (#{controller}##{action})"
      { "a member" => [ member, "Admin access required" ], "a kid profile" => [ headers.merge(kid), "Not from a kid profile" ] }
        .each do |who, (as, error)|
          send(verb.downcase, url, headers: as, as: :json)
          # A kid may be refused sooner, by a title it can't see at all.
          refused = response.status == 403 ? json["errors"] == [ error ] : who == "a kid profile" && response.status == 404
          failures << "#{label} let #{who} through (#{response.status})" unless refused
          failures << "#{label} changed #{changed_tables(before).join(', ')} for #{who}" if changed_tables(before).any?
          before = world_digest
        end
    end

    expect(failures).to be_empty, failures.join("\n")
  end

  # Every catalog read goes through Viewing::Access (CLAUDE.md). This
  # household's titles are all unrated, so a kid held to a ceiling may see
  # none of them — on any page.
  it "shows a kid profile none of what its ceiling hides, on any page" do
    ours = world_for(household)
    kid = profile_header(Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 7))
    leaks = []

    api_routes.each do |verb, path, controller, action|
      next unless verb == "GET" && !admin_only?(controller, action) && !EXEMPT.key?(controller) && !EXEMPT.key?("#{controller}##{action}")
      next if GROWN_UPS_ONLY.include?("#{controller}##{action}")

      get fill(path, ours, controller), headers: headers.merge(kid)
      # Titles only: a library's, collection's or person's name isn't rated.
      found = response.body.scan(/#{MARKER} (?:Heat|Nights|Pilot|Channel|Video|Download|Beach|Summer|List|Nine|Hanna)\b/).uniq
      leaks << "GET #{path} (#{controller}##{action}): #{found.join(', ')}" if found.any?
    end

    expect(leaks).to be_empty, leaks.join("\n")
    GROWN_UPS_ONLY.each do |endpoint|
      verb, path = api_routes.find { |_, _, controller, action| "#{controller}##{action}" == endpoint }
      get fill(path, ours, endpoint.split("#").first), headers: headers.merge(kid)
      expect(response).to have_http_status(:forbidden), "#{verb} #{path} let a kid profile in"
    end
  end
end

# typed: strict
# frozen_string_literal: true

Rails.application.routes.draw do
  # Health endpoint for fog's swap gate + monitor: unauthenticated, <500 = ok.
  get "up" => "rails/health#show", as: :rails_health_check

  # The OpenAPI document and its browser (PROPOSAL §7.6), generated from
  # spec/requests/openapi by `bin/rails rswag:specs:swaggerize`.
  mount Rswag::Ui::Engine => "/api-docs"
  mount Rswag::Api::Engine => "/api-docs"

  # Sign in with fog (fog:docs/signin-proposal.md §15): plain OpenID Connect,
  # so any provider OIDC_ISSUER names works the same way.
  scope "auth/oidc", controller: "auth/oidc" do
    get "start", action: :start, as: :oidc_start
    get "callback", action: :callback, as: :oidc_callback
    post "backchannel", action: :backchannel, as: :oidc_backchannel
    post "link", action: :link, as: :oidc_link
  end

  namespace :api do
    namespace :v1 do
      resource :setup, only: %i[show create], controller: "setup" do
        # Restore-from-backup: the wizard's alternative to creating a fresh
        # household (fog-backup/1).
        post :restore
      end
      resource :session, only: %i[create destroy]
      # The console trades a fog sign-in's one-time code for its session.
      resource :handoff, only: :create
      # Passkeys (WebAuthn): sign in, and manage the signed-in user's credentials.
      namespace :auth do
        post "passkey/login/begin" => "passkeys#login_begin"
        post "passkey/login/finish" => "passkeys#login_finish"
      end
      resources :webauthn_credentials, only: %i[index destroy] do
        collection do
          post "register/begin" => "webauthn_credentials#register_begin"
          post "register/finish" => "webauthn_credentials#register_finish"
        end
      end
      resources :invites, only: :create do
        post :accept, on: :collection
      end
      get "me" => "users#me"
      resources :users, only: :index
      resources :notifications, only: :index do
        post :read, on: :member
        post :read_all, on: :collection
      end

      resources :libraries, only: %i[index show create update destroy] do
        post :scan, on: :member
        post :rematch, on: :member
        post :validate_path, on: :collection
        get :fog_suggestions, on: :collection
      end
      # Cameras and web streams (PROPOSAL §7.8).
      resources :live_streams, only: %i[index show create update destroy] do
        post :test, on: :collection
        post :probe, on: :member
      end
      # Remote transcoders: admins manage nodes; workers poll and upload.
      resources :transcode_nodes, only: %i[index create update destroy]
      scope :transcoder, controller: :transcoder, as: :transcoder do
        post :poll
        put "runs/:id/files/:name" => "transcoder#upload", as: :upload, constraints: { name: /[\w.-]+/ }, format: false
        get :worker
      end
      # What the household's screens decode, for hook's release scoring.
      get "devices/capabilities" => "devices#capabilities"
      scope :remote, controller: :remote, as: :remote do
        match "this_device", action: :this_device, via: %i[get patch]
        get :commands
        get :devices
        post "devices/:id/commands", action: :send_command, as: :send_command
      end
      scope :artwork_choices, controller: :artwork_choices, as: :artwork_choices do
        get "/" => "artwork_choices#index", as: :list
        put :choose
        post :upload
        delete :reset
      end
      resources :offline_downloads, only: %i[create destroy] do
        post :progress, on: :member
      end
      resources :optimized_versions, only: %i[index create destroy] do
        get :status, on: :collection
        post :bulk, on: :collection
        post :scan, on: :collection
      end
      resources :media_files, only: %i[index show] do
        post :rerun, on: :member
        put "markers/:kind" => "media_files#set_marker", on: :member, as: :marker
        delete "markers/:kind" => "media_files#clear_marker", on: :member
      end

      resource :tmdb_setting, only: %i[show update destroy] do
        post :test
      end
      resource :home, only: %i[show update], controller: "home" do
        match :pin, via: %i[post delete]
      end
      resource :sidebar, only: %i[show update], controller: "sidebar"
      resource :catalog_version, only: :show, controller: "catalog_version"
      resource :search, only: :show, controller: "search"
      # Asking Hook from the palette (PROPOSAL §7.9).
      resource :hook, only: :show, controller: "hook_requests" do
        get :search
        post :test
        post :movies, action: :movie
        post :shows, action: :show_seasons
        post "shows/:id/want", action: :want_show, as: :want_show
      end
      resources :people, only: :show
      resource :profile_tags, only: %i[update] do
        get "/" => "profile_tags#index", as: :list
      end
      resources :channels, only: %i[index show] do
        post :watched, on: :member
        resource :tracking, only: %i[show update], controller: "channel_tracking" do
          post :link
          post :poll
          post "downloads/:download_id/retry" => "channel_tracking#retry", as: :retry
          patch "downloads/:download_id" => "channel_tracking#keep", as: :keep
        end
      end
      resources :subscriptions, only: :index
      post "channels/:channel_id/subscription" => "subscriptions#create", as: :channel_subscription
      delete "channels/:channel_id/subscription" => "subscriptions#destroy"
      resource :watch_later, only: %i[show create destroy], controller: "watch_later"
      resource :youtube, only: %i[show update], controller: "youtube" do
        post :resolve
        post :track
        post :update_tool
        patch :sponsorblock
        patch :end_screen
      end
      resource :sponsorblock_preferences, only: %i[show update]
      resource :viewing_preferences, only: %i[show update]
      resource :whisper_setting, only: %i[show update destroy] do
        post :test
      end
      resource :transcript, only: :show
      resources :pairings, only: %i[create show] do
        post :approve, on: :collection
      end
      get "stats/now_playing" => "stats#now_playing"
      get "stats/history" => "stats#history"
      get "stats/summary" => "stats#summary"
      resource :notification_preferences, only: %i[show update] do
        post :test
      end
      resource :open_subtitles_setting, only: %i[show update destroy] do
        post :test
      end
      resource :mlb_setting, only: %i[show update destroy] do
        post :test
      end
      resource :baseball, only: :show, controller: "baseball" do
        get :games
        post "games/:id/watch", action: :watch, as: :watch
      end
      resource :nba_setting, only: %i[show update destroy] do
        post :test
      end
      resource :basketball, only: :show, controller: "basketball" do
        get :games
      end
      resources :videos, only: %i[index show] do
        post :watched, on: :collection
        member do
          post :identify
          post :not_on_youtube
        end
      end
      resources :clips, only: %i[index show] do
        get :places, on: :collection
        get :filters, on: :collection
      end
      resource :immich_setting, only: %i[show update destroy] do
        post :test
        post :sync
      end
      resource :trakt_setting, only: %i[show update destroy] do
        post :test
      end
      resource :trakt_account, only: %i[show create destroy] do
        post :poll
        post :sync
      end
      resource :rating, only: :update
      resources :playlists, only: %i[index show create update destroy] do
        member do
          post :items, action: :add_item
          delete :items, action: :remove_item
          put :order, action: :reorder
        end
      end
      patch "metadata/:kind/:id" => "metadata#update", as: :metadata
      post "metadata/:kind/:id/refresh" => "metadata#refresh", as: :metadata_refresh
      resources :collections, only: %i[index show create update destroy] do
        member do
          post :items, action: :add_item
          delete :items, action: :remove_item
          put :order, action: :reorder
        end
      end
      # Grid (PROPOSAL §7.7).
      resources :stations, only: %i[index show create update destroy] do
        get :options, on: :collection
        post :preview, on: :collection
        get :preset, on: :collection
        member do
          put :hide
          delete :hide, action: :unhide
          put :favorite
          delete :favorite, action: :unfavorite
        end
      end
      resources :airings, only: [] do
        member do
          put :reminder, action: :remind
          delete :reminder, action: :forget
        end
      end
      resource :guide, only: :show, controller: "guide"
      resources :episodes, only: [] do
        get :identity, on: :member
      end
      resources :movies, only: %i[index show] do
        get :letters, on: :collection
        get :similar, on: :member
      end
      resources :shows, only: %i[index show] do
        get :letters, on: :collection
        get "seasons/:season_number" => "shows#season", on: :member, as: :season
        get :episodes, on: :member
        get :progress, on: :member
        get :info, on: :member
        post :watched, on: :member
        patch :preferences, on: :member
        get :similar, on: :member
      end
      resources :watch_states, only: :create do
        post :hide, on: :collection
      end
      resources :playback_sessions, only: %i[create destroy] do
        # Still playable? The corner's resume card asks before it's offered.
        get :readable, on: :collection
        # A Grid channel tuned ahead on standby, switched to — and back
        # on standby when switched away from (PROPOSAL §7.7).
        post :watch, on: :member
        post :standby, on: :member
        # A failed play carries on one rung down the ladder, and one that
        # fell back for a passing reason climbs back.
        post :fallback, on: :member
        post :upgrade, on: :member
      end
      # What plays have taught about files on each kind of client,
      # and forgetting it.
      resources :playback_lessons, only: %i[index destroy]
      get "playback_decisions" => "playback_decisions#index"
      get "playback_decisions/summary" => "playback_decisions#summary"
      get "playback_decisions/transcode_report" => "playback_decisions#transcode_report"
      get "playback_decisions/facets" => "playback_decisions#facets"
      get "playback_decisions/health" => "playback_decisions#health"
      get "playback_decisions/:id" => "playback_decisions#show", as: :playback_decision

      resource :arr_webhook, only: :show do
        post :regenerate
        post "path_mappings" => "arr_webhooks#create_mapping"
        delete "path_mappings/:mapping_id" => "arr_webhooks#destroy_mapping"
      end

      resources :profiles, only: %i[index create update destroy] do
        get :current, on: :collection
        post :select, on: :member
        resource :content, only: :show, controller: "profile_content" do
          put :hidden
        end
      end
      resource :plex_connection, only: %i[show update destroy] do
        post :test
        patch "users/:mapping_id" => "plex_connections#map_user", as: :user
      end
      resources :plex_imports, only: %i[index create]

      get "matches" => "matches#index"
      get "matches/folders" => "matches#folders", as: :match_folders
      post "matches/show/:id/reject" => "matches#reject", as: :match_reject
      post "matches/:kind/:id/search" => "matches#search", as: :match_search
      post "matches/:kind/:id" => "matches#create", as: :match_choose

      resources :api_tokens, only: %i[index create destroy]
      resource :app_setting, only: %i[show update], controller: "app_settings"

      get "background_jobs" => "background_jobs#index"
      post "background_jobs/:key/run" => "background_jobs#run", as: :run_background_job

      # "events", not "activity": EasyPrivacy-class blocklists kill any
      # request matching */activity, so with an ad blocker installed the
      # Activity page rendered as a permanent error. The controller keeps
      # its name; only the URL is camouflage.
      get "events" => "activity#index"
      resource :about, only: :show, controller: "about"
    end
  end

  # fog-backup/1 machine surface (fog:docs/backup-contract.md): fog drives
  # delegated backups and restores through here, authenticated by the
  # fog-injected FOG_API_TOKEN — never by console sessions.
  scope "fog", controller: :fog, defaults: { format: :json } do
    get "backup", action: :descriptor
    post "backup", action: :create_backup
    get "backup/jobs/:id", action: :job_status, as: :fog_backup_job
    get "backup/jobs/:id/artifact", action: :artifact, as: :fog_backup_artifact
    delete "backup/jobs/:id", action: :destroy_job
    post "restore", action: :restore, as: :fog_restore
  end
  # fog-files/1 (fog:docs/files-contract.md): a folder Stream mounts changed.
  post "fog/files/changed" => "fog_files#changed", defaults: { format: :json }
  # fog-integration/1 (fog:docs/integrations-contract.md): fog mints and
  # revokes another app's Stream token when the operator connects it.
  scope "fog", defaults: { format: :json } do
    resources :integrations, controller: :fog_integrations, only: %i[create show destroy], as: :fog_integrations
  end

  # Media bytes and progress, authorized by the stream token in the path
  # (PROPOSAL §3.3).
  # What an offline download fetches (Playback::DownloadToken).
  scope "media/d/:token", controller: :download_media, constraints: { token: /[^\/]+/ } do
    get "file.:ext", action: :file, as: :download_file
    get "subtitles/:track.vtt", action: :subtitle, as: :download_subtitle, constraints: { track: /[a-z0-9]+/ }
  end
  # A remote transcoder's ffmpeg reading an original (Playback::RunToken).
  get "media/n/:token/source" => "node_media#source", as: :node_media_source, constraints: { token: /[^\/]+/ }

  # fog-compute/1 (fog:docs/compute-contract.md): fog, as each pool of
  # machines paired with it, by FOG_API_TOKEN; and what those machines
  # reach through fog's data route, by the run token in the path alone.
  scope "fog/compute", defaults: { format: :json } do
    post "transcoders" => "fog_compute#create", as: :fog_compute_transcoders
    delete "transcoders/:id" => "fog_compute#destroy", as: :fog_compute_transcoder
    post "transcoders/:id/poll" => "fog_compute#poll", as: :fog_compute_poll
  end
  scope "fog/compute/runs/:token", controller: :fog_compute_runs, constraints: { token: /[^\/]+/ }, format: false do
    get "source", action: :source, as: :fog_compute_run_source
    put "files/:name", action: :upload, as: :fog_compute_run_upload, constraints: { name: /[\w.-]+/ }
  end
  scope "media/s/:token", controller: :media, constraints: { token: /[^\/]+/ } do
    get "original.:ext", action: :original, as: :media_original
    get "hls/index.m3u8", action: :playlist, as: :media_playlist
    get "hls/init.mp4", action: :init, as: :media_init
    get "hls/seg-:index.m4s", action: :segment, as: :media_segment, constraints: { index: /\d+/ }
    # Adaptive bitrate: each version of the stream (Playback::Variants).
    get "hls/v:variant/index.m3u8", action: :playlist, as: :media_variant_playlist, constraints: { variant: /\d+/ }
    get "hls/v:variant/init.mp4", action: :init, as: :media_variant_init, constraints: { variant: /\d+/ }
    get "hls/v:variant/seg-:index.m4s", action: :segment, as: :media_variant_segment, constraints: { variant: /\d+/, index: /\d+/ }
    # A live stream's relay (PROPOSAL §7.8).
    get "live/index.m3u8", action: :live_playlist, as: :media_live_playlist
    get "live/:name.:ext", action: :live_file, as: :media_live_file, constraints: { name: /init|seg-\d+/, ext: /mp4|m4s/ }
    post "progress", action: :progress, as: :media_progress
    post "events", action: :events, as: :media_events
    get "subtitles/:track.:format", action: :subtitle, as: :media_subtitle, constraints: { track: /[a-z0-9]+/, format: /vtt|ass|sup/ }
    get "trickplay/:version/sheet-:index.webp", action: :trickplay, as: :media_trickplay, constraints: { version: /\d+/, index: /\d+/ }
    get "fonts/:name", action: :font, as: :media_font, constraints: { name: /[\w.-]+/ }
  end

  # Sonarr/Radarr Connect webhooks, authenticated by the token in the URL.
  post "hooks/arr/:token" => "hooks#arr", as: :arr_hook

  # A live stream's card picture (PROPOSAL §7.8): signed, no session.
  get "artwork/live/:id/:version" => "live_stills#show", as: :live_still,
    constraints: { id: /[0-9a-f-]{36}/, version: /\d+/ }, format: "webp"
  # Rendered artwork, fetched by <img> tags: signed URLs, no session.
  get "artwork/:id/:version/:width" => "artwork#show", as: :artwork,
    constraints: { id: /[0-9a-f-]{36}/, version: /\d+/, width: /\d+/ }, format: "webp"

  # A title's trailer, fetched by <video>: a signed URL, no session.
  get "trailers/:id/:signature" => "trailers#show", as: :trailer, format: "mp4",
    constraints: { id: /[0-9a-f-]{36}/, signature: /[0-9a-f]+/ }

  # The MCP surface (PROPOSAL §11 Phase 6), authenticated by an API token.
  match "mcp", to: "mcp#handle", via: %i[get post delete], as: :mcp

  # A bundle an older build named (StaleAssetsController). Every file that
  # exists is served by ActionDispatch::Static before routing.
  get "assets/*path" => "stale_assets#show", format: false,
    constraints: ->(req) { req.path.end_with?(".js") }

  # SPA fallback — every non-API, non-asset path renders the shell so
  # client-side routes survive a refresh.
  get "*path" => "spa#show", constraints: ->(req) {
    !req.path.start_with?("/api", "/up", "/assets", "/rails", "/fog", "/media", "/artwork", "/hooks", "/mcp", "/trailers", "/auth/oidc")
  }
  root "spa#show"
end

# typed: false
# frozen_string_literal: true

require "rails_helper"

# The pages a household opens most, each held to the same number of queries
# however much is in the library (spec/support/query_counting.rb): a preload
# that quietly turns back into an N+1 fails here, not on the TV.
RSpec.describe "Query shape", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let!(:headers) { auth_headers(admin) }
  let!(:profile) { Profile.default_for(household) }
  let(:films) { create_library(household: household, roots: build_root, name: "Films") }
  let(:tv) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }

  def media_file(library)
    MediaFile.create!(household: household, library: library, path: "/m/#{SecureRandom.hex(4)}.mkv", size: 1, mtime: Time.current,
      state: "probed", duration_seconds: 1200)
  end

  def movie(title)
    Movie.create!(household: household, library: films, title: title, content_rating: "PG").tap do |film|
      film.editions.create!(media_file: media_file(films))
      WatchState.create!(profile: profile, playable: film, position_seconds: 300, duration_seconds: 1200, last_watched_at: Time.current)
    end
  end

  def show(title, episodes: 3)
    Show.create!(household: household, library: tv, folder: title, title: title, content_rating: "TV-PG").tap do |series|
      season = series.seasons.create!(season_number: 1)
      (1..episodes).each do |number|
        series.episodes.create!(season: season, season_number: 1, episode_number: number, title: "#{title} #{number}")
          .tap { |episode| episode.editions.create!(media_file: media_file(tv)) }
      end
      WatchState.create!(profile: profile, playable: series.episodes.first, completed_at: Time.current, last_watched_at: Time.current,
        play_count: 1)
    end
  end

  def station(number, series)
    Station.create!(household: household, number: number, name: "Channel #{number}").tap do |made|
      series.episodes.each_with_index do |episode, index|
        Airing.create!(household: household, station: made, playable: episode, media_file: episode.media_files.first, series_key: series.id,
          starts_at: Time.current + (index * 20).minutes, ends_at: Time.current + ((index + 1) * 20).minutes, reason: "Test")
      end
    end
  end

  # Queries for one request once the page has something on it, then again
  # with more of everything: the second must not be larger.
  def expect_flat(path, params = {}, grow:)
    get path, params: params, headers: headers
    expect(response).to have_http_status(:ok)
    small = count_queries { get path, params: params, headers: headers }
    grow.call
    large = count_queries { get path, params: params, headers: headers }
    expect(large.size).to eq(small.size), "#{path}: #{small.size} queries, then #{large.size}\n#{grown(small, large).join("\n")}"
  end

  # The kinds of query that happened more often the second time.
  def grown(small, large)
    shape = ->(sql) { sql.gsub(/\$\d+(, \$\d+)*/, "?").gsub(/'[^']*'/, "?") }
    before = small.map(&shape).tally
    large.map(&shape).tally.filter_map { |sql, count| "#{count - before.fetch(sql, 0)}× #{sql.truncate(300)}" if count > before.fetch(sql, 0) }
  end

  it "keeps Home flat" do
    2.times { |i| movie("Film #{i}") && show("Show #{i}") }
    expect_flat("/api/v1/home", grow: -> { 4.times { |i| movie("More #{i}") && show("More show #{i}") } })
  end

  it "keeps Home flat for a restricted profile" do
    younger = Profile.create!(household: household, name: "Younger", max_rating_age: 10, position: 1)
    as_younger = headers.merge(profile_header(younger))
    2.times { |i| movie("Film #{i}") && show("Show #{i}") }
    get "/api/v1/home", headers: as_younger
    small = count_queries { get "/api/v1/home", headers: as_younger }
    4.times { |i| movie("More #{i}") && show("More show #{i}") }
    large = count_queries { get "/api/v1/home", headers: as_younger }

    expect(large.size).to eq(small.size), grown(small, large).join("\n")
  end

  it "keeps a season page flat however many episodes it has" do
    series = show("Office", episodes: 2)
    expect_flat("/api/v1/shows/#{series.id}/seasons/1", grow: -> {
      season = series.seasons.first
      (3..10).each do |number|
        series.episodes.create!(season: season, season_number: 1, episode_number: number, title: "Office #{number}")
          .tap { |episode| episode.editions.create!(media_file: media_file(tv)) }
      end
    })
  end

  it "keeps the shows grid and search flat" do
    2.times { |i| show("Grid #{i}") && movie("Grid film #{i}") }
    expect_flat("/api/v1/shows", grow: -> { 5.times { |i| show("Grid more #{i}") } })
    expect_flat("/api/v1/search", { q: "grid" }, grow: -> { 5.times { |i| show("Grid late #{i}") && movie("Grid late film #{i}") } })
  end

  it "names the episodes search heard something said in without asking for each one's show" do
    said = lambda do |title|
      show(title, episodes: 1).episodes.first.media_files.first.then do |file|
        transcript = Transcript.create!(media_file: file, source: "subtitles")
        TranscriptLine.create!(transcript: transcript, media_file: file, start_seconds: 1.0, end_seconds: 2.0, text: "We were on a break")
      end
    end
    2.times { |i| said.call("Friends #{i}") }
    expect_flat("/api/v1/search", { q: "on a break" }, grow: -> { 4.times { |i| said.call("Friends later #{i}") } })
  end

  it "keeps a show's episode inventory and progress flat however many episodes it has" do
    series = show("Office", episodes: 2)
    grow = lambda do |from|
      -> {
        season = series.seasons.first
        (from..(from + 6)).each do |number|
          episode = series.episodes.create!(season: season, season_number: 1, episode_number: number, title: "Office #{number}")
          episode.editions.create!(media_file: media_file(tv))
          WatchState.create!(profile: profile, playable: episode, completed_at: Time.current, last_watched_at: Time.current, play_count: 1)
        end
      }
    end
    expect_flat("/api/v1/shows/#{series.id}/episodes", grow: grow.call(3))
    expect_flat("/api/v1/shows/#{series.id}/progress", grow: grow.call(10))
  end

  it "keeps the file list flat, with what each file is of" do
    2.times { |i| movie("Film #{i}") && show("Show #{i}") }
    expect_flat("/api/v1/media_files", grow: -> { 3.times { |i| movie("More #{i}") && show("More show #{i}") } })
  end

  it "keeps the Grid guide flat however many channels there are" do
    station("2", show("Guide A"))
    expect_flat("/api/v1/guide", grow: -> { (3..8).each { |number| station(number.to_s, show("Guide #{number}")) } })
  end

  it "keeps the playlists page flat for a restricted profile too, however many playlists it has" do
    younger = Profile.create!(household: household, name: "Younger", max_rating_age: 10, position: 1)
    as_younger = headers.merge(profile_header(younger))
    list = ->(title) do
      Playlist.create!(household: household, profile: younger, title: title).tap do |made|
        PlaylistItem.create!(playlist: made, item: movie("#{title} film"), position: 1)
        PlaylistItem.create!(playlist: made, item: show("#{title} show", episodes: 1).episodes.first, position: 2)
      end
    end
    list.call("One")
    get "/api/v1/playlists", headers: as_younger
    small = count_queries { get "/api/v1/playlists", headers: as_younger }
    (2..6).each { |number| list.call("List #{number}") }
    large = count_queries { get "/api/v1/playlists", headers: as_younger }

    expect(large.size).to eq(small.size), grown(small, large).join("\n")
    expect(response.parsed_body.reject { |row| row["watch_later"] }.pluck("item_count")).to all(eq(2))
  end

  it "keeps a playlist flat however long it is" do
    playlist = Playlist.create!(household: household, profile: profile, title: "Rainy day")
    add = ->(title, at) { PlaylistItem.create!(playlist: playlist, item: movie(title), position: at) }
    2.times { |i| add.call("Rain #{i}", i + 1) }
    expect_flat("/api/v1/playlists/#{playlist.id}", grow: -> { (3..9).each { |i| add.call("Rain #{i}", i) } })
    expect_flat("/api/v1/playlists", grow: -> { 3.times { |i| Playlist.create!(household: household, profile: profile, title: "More #{i}") } })
  end

  def video(title)
    youtube = Library.find_by(household: household, kind: "channels") ||
      create_library(household: household, roots: build_root, kind: "channels", name: "YouTube")
    maker = Channel.create!(household: household, library: youtube, folder: title, title: "#{title} channel")
    Video.create!(household: household, library: youtube, channel: maker, title: title, source: "folder").tap do |made|
      made.editions.create!(media_file: media_file(youtube))
    end
  end

  def played(playable)
    PlaybackSession.create!(household: household, profile: profile, playable: playable, media_file: playable.media_files.first,
      method: "direct", decision: { "summary" => "Plays as-is" }, device_name: "Chrome", started_at: 1.hour.ago, last_seen_at: 30.minutes.ago)
  end

  it "keeps Home flat however many videos are being continued" do
    resume = ->(title) { WatchState.create!(profile: profile, playable: video(title), position_seconds: 60, duration_seconds: 1200, last_watched_at: Time.current) }
    2.times { |i| resume.call("Clip #{i}") }
    expect_flat("/api/v1/home", grow: -> { 5.times { |i| resume.call("Later clip #{i}") } })
  end

  # A video's artwork, progress and length, asked once for every video on
  # Home, not again for each row it's in (Continue watching, New in YouTube,
  # New from your subscriptions).
  it "cards Home's videos in one pass, however many rows show them" do
    continued = video("Clip")
    WatchState.create!(profile: profile, playable: continued, position_seconds: 60, duration_seconds: 1200, last_watched_at: Time.current)
    ChannelSubscription.create!(profile: profile, channel: video("Fresh").channel)
    get "/api/v1/home", headers: headers

    lengths = count_queries(matching: /"duration_seconds"/) { get "/api/v1/home", headers: headers }
    expect(lengths.size).to eq(1), lengths.join("\n")
    rows = response.parsed_body["hubs"].to_h { |hub| [ hub["key"], hub["items"].pluck("title") ] }
    expect(rows).to include("continue_watching" => [ "Clip" ], "subscriptions" => [ "Fresh" ])
  end

  it "keeps the collections list flat however many collections there are" do
    shelf = ->(title) do
      Collection.create!(household: household, kind: "manual", title: title).tap do |made|
        2.times { |i| made.collection_items.create!(item: movie("#{title} #{i}"), position: i) }
      end
    end
    2.times { |i| shelf.call("Shelf #{i}") }
    expect_flat("/api/v1/collections", grow: -> { 6.times { |i| shelf.call("Later shelf #{i}") } })
  end

  it "keeps the admin's playback lists flat however many shows and channels were watched" do
    watch = ->(title) do
      played(show(title, episodes: 1).episodes.first)
      played(video("#{title} video"))
    end
    2.times { |i| watch.call("Seen #{i}") }
    more = ->(round) { -> { 5.times { |i| watch.call("Seen #{round} #{i}") } } }
    expect_flat("/api/v1/playback_decisions", grow: more.call("again"))
    expect_flat("/api/v1/stats/history", grow: more.call("since"))
    expect_flat("/api/v1/stats/summary", grow: more.call("lately"))
    PlaybackSession.update_all(state: "active", last_seen_at: Time.current)
    expect_flat("/api/v1/stats/now_playing", grow: -> { more.call("now").call && PlaybackSession.update_all(state: "active", last_seen_at: Time.current) })
  end

  it "keeps the optimized versions list flat however many shows have one" do
    optimize = ->(title) do
      file = show(title, episodes: 1).episodes.first.media_files.first
      OptimizedVersion.create!(household: household, media_file: file, state: "ready", height: 1080, size: 10)
    end
    2.times { |i| optimize.call("Small #{i}") }
    expect_flat("/api/v1/optimized_versions", grow: -> { 5.times { |i| optimize.call("Small later #{i}") } })
  end

  it "names the files a device would convert without asking for each one's show" do
    Device.create!(household: household, client_key: "c", name: "Chrome on macOS", last_seen_at: Time.current,
      capabilities: { "hls" => "mse", "video" => %w[h264 vp9], "audio" => %w[aac opus], "containers" => %w[mp4 webm] })
    hevc = ->(title) do
      file = show(title, episodes: 1).episodes.first.media_files.first
      file.update!(container: "matroska,webm")
      file.media_streams.create!(index: 0, kind: "video", codec: "hevc", bit_depth: 10, height: 2160)
      file.media_streams.create!(index: 1, kind: "audio", codec: "aac", channels: 2)
    end
    report = -> { count_queries { Playback::Report.needing_conversion(household) } }
    2.times { |i| hevc.call("Remux #{i}") }
    small = report.call
    6.times { |i| hevc.call("Remux later #{i}") }
    large = report.call

    expect(large.size).to eq(small.size), grown(small, large).join("\n")
    # Every file is read for this, so never its probe or keyframe index.
    expect(large.grep(/FROM "media_files"/).grep(/"probe"|"keyframes"|"media_files"\.\*/)).to be_empty
    expect(Playback::Report.needing_conversion(household).map { |row| row[:title] }).to include("Remux 0 S01E01", "Remux later 5 S01E01")
  end

  # Pressing Play reads what plays have taught (Playback::Learned) once for
  # every version of the title, not once to choose and again to place.
  it "keeps a press of Play flat however many versions the title has" do
    require_ffprobe!
    film = Movie.create!(household: household, library: films, title: "Heat", content_rating: "PG")
    root = films.roots.first
    version = lambda do
      name = "Heat #{SecureRandom.hex(3)}.mp4"
      FileUtils.cp(media_fixture("h264_aac.mp4"), File.join(root, name))
      settle_library_roots!(root)
      file = MediaFile.create!(household: household, library: films, path: File.join(root, name), size: File.size(File.join(root, name)),
        mtime: Time.current, state: "discovered")
      Media::FileProber.new(file).call
      film.editions.create!(media_file: file)
    end
    chrome = { "hls" => "mse", "video" => %w[h264], "audio" => %w[aac], "containers" => %w[mp4], "max_audio_channels" => 2, "max_height" => 2160 }
    ua = { "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/141.0.7390.54 Safari/537.36" }
    play = lambda do
      count_queries do
        post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: film.id, capabilities: chrome },
          headers: headers.merge(ua)
        expect(response).to have_http_status(:created), response.body
      end
    end
    version.call
    play.call
    small = play.call
    3.times { version.call }
    play.call
    large = play.call

    learned = ->(queries) { queries.grep(/playabilities/) }
    expect(learned.call(large).size).to eq(2), learned.call(large).join("\n")
    expect(large.size).to eq(small.size), grown(small, large).join("\n")
  end

  it "keeps the history flat however many sessions played an optimized version" do
    optimized = lambda do |title|
      episode = show(title, episodes: 1).episodes.first
      OptimizedVersion.create!(household: household, media_file: episode.media_files.first, state: "ready", height: 1080, size: 10)
      played(episode).update!(method: "optimized")
    end
    2.times { |i| optimized.call("Small #{i}") }
    expect_flat("/api/v1/stats/history", grow: -> { 5.times { |i| optimized.call("Small later #{i}") } })
  end

  it "keeps the transcoders list flat however many transcoders and runs there are" do
    node = lambda do |name|
      TranscodeNode.generate(name: name).node.tap do |made|
        2.times do |i|
          session = played(show("#{name} #{i}", episodes: 1).episodes.first)
          TranscodeRun.create!(transcode_node: made, playback_session: session, argv: %w[ffmpeg -version])
        end
        file = movie("#{name} film").media_files.first
        version = OptimizedVersion.create!(household: household, media_file: file, state: "queued")
        TranscodeRun.create!(transcode_node: made, optimized_version: version, argv: %w[ffmpeg -version])
      end
    end
    node.call("Mac mini")
    expect_flat("/api/v1/transcode_nodes", grow: -> { %w[Studio Laptop Den].each { |name| node.call(name) } })
    titles = response.parsed_body["nodes"].flat_map { |row| row["runs"].pluck("title") }
    expect(titles).to include("Den 0 S01E01", "Mac mini 1 S01E01")
  end

  it "keeps the screens list flat however many screens are playing" do
    screen = lambda do |name|
      device = Device.create!(household: household, client_key: SecureRandom.hex(4), name: name, last_seen_at: Time.current,
        remote_control: true, remote_seen_at: Time.current)
      played(show("#{name} show", episodes: 1).episodes.first).update!(device: device, state: "active", last_seen_at: Time.current)
      played(video("#{name} video")).update!(device: device, state: "active", last_seen_at: 1.minute.ago)
    end
    screen.call("Den")
    expect_flat("/api/v1/remote/devices", grow: -> { %w[Kitchen Bedroom Office].each { |name| screen.call(name) } })
    expect(response.parsed_body.map { |row| row.dig("now_playing", "title") }).to all(end_with("show"))
  end

  it "keeps Activity flat however long the timeline is" do
    record = -> { Activity.record(source: "library", event: "library.scanned", subject: films, household_id: household.id, summary: "Scanned") }
    3.times { record.call }
    expect_flat("/api/v1/events", grow: -> { 10.times { record.call } })
  end
end

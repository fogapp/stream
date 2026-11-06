# typed: false
# frozen_string_literal: true

# Fixtures for the browser harness (frontend/e2e). Everything lives in its
# own household, so a run never reads or writes the household you actually
# develop against — and `e2e:clean` is a single destroy.
#
# Idempotent: re-running resets the fixture household to the same known
# shape, which is what lets a spec assert on exact titles and counts.
# Runs jobs inline, scheduled ones included (the stock inline adapter
# refuses those).
class E2eInlineAdapter < ActiveJob::QueueAdapters::InlineAdapter
  def enqueue_at(job, _timestamp) = enqueue(job)
end

namespace :e2e do
  HOUSEHOLD_NAME = "E2E Harness"
  EMAIL = "e2e@example.com"
  PASSWORD = "passwordpassword"

  desc "Seed (or reset) the browser harness household and print its credentials"
  task seed: :environment do
    Rake::Task["e2e:clean"].invoke

    household = Household.create!(name: HOUSEHOLD_NAME)
    household.users.create!(name: "Ellie Harness", email: EMAIL, password: PASSWORD, role: "admin")

    # Two rows for the bell and the Notifications page: one that links
    # somewhere, one that has nowhere to go.
    users = household.users.to_a
    Notifier.notify(users: users, kind: "scan_finished", icon: "\u{1F3AC}", path: "/settings?tab=about",
      title: "Movies: 3 new titles found", dedupe_key: "e2e:scan_finished")
    Notifier.notify(users: users, kind: "library_unreachable", icon: "\u{26A0}\u{FE0F}",
      title: "TV is not visible from inside Stream", dedupe_key: "e2e:library_unreachable")

    seed_media(household)

    puts({ email: EMAIL, password: PASSWORD, household: household.id }.to_json)
  end

  # A real media library built from the fixture corpus, read by the real
  # scanner, prober, matcher and frame grabber (no TMDB: titles come from the
  # file names). WebM copies are the ones Playwright's Chromium can play — it
  # ships without H.264. The MKV is there to be refused (Phase 1 has no
  # remux).
  MEDIA = {
    "movies/Heat (1995)/Heat (1995).webm" => "vp9_opus.webm",
    # A second version and a trailer: the version picker and extras.
    "movies/Heat (1995)/Heat (1995) {edition-Director's Cut}.webm" => "vp9_opus.webm",
    "movies/Heat (1995)/Heat (1995)-trailer.webm" => "vp9_opus.webm",
    "movies/Alien (1979)/Alien (1979).mp4" => "h264_aac.mp4",
    "movies/Primer (2004)/Primer (2004).mkv" => "h264_aac_ac3_subs.mkv",
    "tv/Severance (2022)/Season 01/Severance - S01E01.webm" => "vp9_opus.webm",
    "tv/Severance (2022)/Season 01/Severance - S01E02.webm" => "av1_opus.webm",
    "channels/Technology Connections/20240131 - The Dishwasher [Ql7w1yX7hbI].webm" => "vp9_opus.webm",
    # Another channel's, for what a finished video offers next.
    "channels/Cleaning Science/20240205 - How Detergent Works [Xk3mPq9sT2a].webm" => "vp9_opus.webm",
    "home/2023/VID_20230714_101500.webm" => "vp9_opus.webm",
    # A title a spec moves on disk, to see its watch state follow it.
    "corpus/Moving Picture (2001)/Moving Picture (2001).webm" => "vp9_opus.webm",
    # A file that probes as broken, for what a failure looks like.
    "unreadable/Broken Film (1999)/Broken Film (1999).mkv" => "truncated.mkv"
  }.freeze

  # Long enough to seek in and to leave a resume point (past
  # WatchState::STARTED_AFTER; the corpus is two seconds a file): an MKV, so
  # Chrome streams it through the transcoder. Made once, then reused.
  LONG_TAKE = "corpus/Long Take (2010)/Long Take (2010).mkv"
  SLOW_CLOCK = "corpus/Slow Clock (2012)/Slow Clock (2012).webm"

  # Title => fixture. Titles are what the spec looks movies up by.
  CORPUS = {
    "Case H264 AAC MP4" => "h264_aac.mp4",
    "Case MKV AC3 Subs" => "h264_aac_ac3_subs.mkv",
    "Case HEVC HDR10" => "hevc_main10_hdr10.mkv",
    "Case AV1 Opus" => "av1_opus.webm",
    "Case VP9 Opus" => "vp9_opus.webm",
    "Case MPEG2 TS" => "mpeg2_mp2.ts",
    "Case Hi10P" => "h264_hi10p.mkv",
    "Case DTS" => "h264_dts.mkv",
    "Case TrueHD" => "h264_truehd.mkv",
    "Case FLAC" => "h264_flac.mkv",
    "Case MovText" => "h264_aac_movtext.mp4"
  }.freeze

  def seed_media(household)
    root = Rails.root.join("tmp", "e2e-media")
    FileUtils.rm_rf(root)
    MEDIA.each do |relative, fixture|
      target = root.join(relative)
      FileUtils.mkdir_p(target.dirname)
      FileUtils.cp(Rails.root.join("spec", "fixtures", "media", fixture), target)
    end
    # yt-dlp's sidecar for the channel video: its details, and a description
    # whose timestamps become chapters.
    File.write(root.join("channels/Technology Connections/20240131 - The Dishwasher [Ql7w1yX7hbI].info.json"), {
      "id" => "Ql7w1yX7hbI", "title" => "The dishwasher, revisited", "upload_date" => "20240131",
      "channel" => "Technology Connections", "channel_id" => "UCy0tKL1T7wFoYcxCe0xjN6Q",
      "description" => "Soap, explained.\nhttps://example.com/soap\n0:00 Intro\n0:01 The pod\n0:02 Outro",
      "webpage_url" => "https://www.youtube.com/watch?v=Ql7w1yX7hbI"
    }.to_json)
    # Its English subtitles, which become its transcript (and search).
    File.write(root.join("channels/Technology Connections/20240131 - The Dishwasher [Ql7w1yX7hbI].en.vtt"),
      "WEBVTT\n\n00:00:00.200 --> 00:00:01.000\nLet's talk about the hyperloop.\n\n00:00:01.000 --> 00:00:01.900\nAnd dishwasher pods.\n")
    # A sidecar subtitle, named the Plex way, for the player's captions menu.
    File.write(root.join("movies/Heat (1995)/Heat (1995).en.srt"),
      "1\n00:00:00,100 --> 00:00:01,900\nA line from the sidecar.\n")

    # The playback suite's corpus (frontend/e2e/playback.spec.ts): every
    # fixture that should play, as a movie named after its case.
    # Made the way a real film is, because that's what broke: B-frames,
    # keyframes wherever (2 to 10 s apart), and Matroska's whole-millisecond
    # timestamps at 23.976 frames a second. A strip across the top of its
    # picture says what second of the film it is — the left half's grey
    # counts seconds in fifties, the right half's counts the fifties — so a
    # spec can tell the frame on screen from the time the player says it is
    # (e2e/support/film.ts). The test card under it is for everything that
    # wants a picture: stills, trickplay, the home page's hero.
    long = Rails.root.join("tmp", "e2e-fixtures", "long_take_strip.mkv")
    unless long.file?
      FileUtils.mkdir_p(long.dirname)
      gaps = [ 5.0, 4.3, 6.7, 10.4, 2.5, 2.1, 4.8, 4.5, 2.1, 10.4, 2.2, 2.4, 3.2, 10.4, 2.0, 3.5, 5.3, 2.6 ]
      keyframes = gaps.cycle.first(60).each_with_object([]) { |gap, times| times << ((times.last || 0.0) + gap) }.select { |time| time < 178 }
      strip = "color=c=black:s=640x120:r=24000/1001:d=180,format=yuv420p," \
              "geq=lum='if(lt(X,320),16+4*mod(floor(T),50),16+40*floor(T/50))':cb=128:cr=128"
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=640x360:rate=24000/1001:duration=180 -f lavfi -i #{strip}
        -f lavfi -i sine=frequency=440:duration=180 -filter_complex [0:v][1:v]overlay=0:0,format=yuv420p[v] -map [v] -map 2:a
        -c:v libx264 -preset veryfast -bf 3 -crf 30 -g 300 -keyint_min 24 -sc_threshold 0
        -force_key_frames #{keyframes.map { |time| format("%.3f", time) }.join(",")} -c:a aac -b:a 64k -shortest #{long}], timeout: 600)
    end
    FileUtils.mkdir_p(root.join(LONG_TAKE).dirname)
    FileUtils.cp(long, root.join(LONG_TAKE))
    # Thirty seconds of VP9 that Playwright's own Chromium can play, for a
    # spec that needs a title to still be playing a moment later (a remote's
    # commands) without touching anything else's watch state.
    clock = Rails.root.join("tmp", "e2e-fixtures", "slow_clock.webm")
    unless clock.file?
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i testsrc2=size=320x180:rate=24:duration=30 -f lavfi -i sine=frequency=330:duration=30
        -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 200k -c:a libopus -b:a 48k -shortest #{clock}], timeout: 300)
    end
    FileUtils.mkdir_p(root.join(SLOW_CLOCK).dirname)
    FileUtils.cp(clock, root.join(SLOW_CLOCK))

    seed_bench(root) if ENV["BENCH"].present?

    CORPUS.each do |title, fixture|
      target = root.join("corpus", "#{title} (2000)", "#{title} (2000)#{File.extname(fixture)}")
      FileUtils.mkdir_p(target.dirname)
      FileUtils.cp(Rails.root.join("spec", "fixtures", "media", fixture), target)
    end
    # A sidecar for the subtitle spec (frontend/e2e/player.spec.ts), on a
    # title nothing else's state depends on.
    File.write(root.join("corpus/Case VP9 Opus (2000)/Case VP9 Opus (2000).en.srt"),
      "1\n00:00:00,100 --> 00:00:01,900\nA line from the sidecar.\n")

    previous = ActiveJob::Base.queue_adapter
    # Inline, and scheduled jobs (the season's intro detection waits five
    # minutes for its neighbours) run now rather than raising.
    ActiveJob::Base.queue_adapter = E2eInlineAdapter.new
    begin
      movies = Library.create!(household: household, name: "Movies", kind: "movies", roots: [ root.join("movies").to_s ])
      tv = Library.create!(household: household, name: "TV Shows", kind: "shows", roots: [ root.join("tv").to_s ])
      corpus = Library.create!(household: household, name: "Corpus", kind: "movies", roots: [ root.join("corpus").to_s ])
      channels = Library.create!(household: household, name: "YouTube", kind: "channels", roots: [ root.join("channels").to_s ])
      home = Library.create!(household: household, name: "Home videos", kind: "home_videos", roots: [ root.join("home").to_s ])
      unreadable = Library.create!(household: household, name: "Unreadable", kind: "movies", roots: [ root.join("unreadable").to_s ])
      libraries = [ movies, tv, corpus, channels, home, unreadable ]
      if ENV["BENCH"].present?
        libraries << Library.create!(household: household, name: "Bench", kind: "movies", roots: [ root.join("bench").to_s ])
      end
      libraries.each { |library| ScanLibraryJob.perform_now(library.id) }
    ensure
      ActiveJob::Base.queue_adapter = previous
    end

    # Markers on the first Severance episode (2 s long): an intro to skip
    # and credits that bring Up next.
    first = Episode.joins(:show).where(shows: { household_id: household.id }, episode_number: 1).first
    first_file = first&.media_files&.first
    if first_file
      Marker.offer(first_file, Marker::Kind::Intro, start: 0.0, finish: 1.2, source: Marker::Source::Manual)
      Marker.offer(first_file, Marker::Kind::Credits, start: 1.4, finish: 2.0, source: Marker::Source::Manual)
    end

    # Heat half-watched, for Continue watching.
    heat = Movie.unscoped.find_by!(household_id: household.id, title: "Heat")
    WatchState.create!(profile: Profile.default_for(household), playable: heat, position_seconds: 1.0,
      duration_seconds: 2.0, last_watched_at: Time.current)

    # The Alien films as TMDB lists them, the household having only the
    # first: the collection shows the rest faded.
    alien = Movie.unscoped.find_by!(household_id: household.id, title: "Alien")
    alien.update!(tmdb_id: 348)
    series = Collection.create!(household_id: household.id, kind: "tmdb", tmdb_id: 8091, title: "Alien Collection",
      overview: "A series of science-fiction horror films.", metadata_refreshed_at: Time.current)
    CollectionItem.create!(collection: series, item: alien)
    [ [ 348, "Alien", "1979-05-25" ], [ 679, "Aliens", "1986-07-18" ], [ 8077, "Alien³", "1992-05-22" ] ].each_with_index do |(id, title, date), index|
      CollectionPart.create!(household_id: household.id, collection: series, tmdb_id: id, title: title, release_date: date, position: index,
        overview: "#{title}, in the series.")
    end

    # A sponsor read in the channel video (SponsorBlock, as if fetched).
    dishwasher = Video.unscoped.find_by!(household_id: household.id, youtube_id: "Ql7w1yX7hbI")
    dishwasher.sponsor_segments.create!(category: "sponsor", start_seconds: 0.3, end_seconds: 1.6, uuid: "e2e-sponsor")

    # The home video as Immich would have filled it in: where, who, which album.
    clip = Clip.unscoped.find_by!(household_id: household.id)
    clip.update!(city: "Brighton", country: "United Kingdom", favorite: true)
    ada = HomePerson.create!(household_id: household.id, immich_id: "e2e-ada", name: "Ada")
    ClipPerson.create!(clip: clip, home_person: ada)
    AlbumClip.create!(album: Album.create!(household_id: household.id, title: "Summer 2023", immich_id: "e2e-summer"), clip: clip)

    # Two Grid channels. The harness's files are seconds long, so their
    # airings are laid down by hand — half an hour an episode, two hours a
    # film — to keep the guide still while a test moves around it.
    # Channel 5 airs the Movies library only: the Corpus's codec cases would
    # make what's on (and how fast it tunes) depend on the time of day.
    movies_library = Library.find_by!(household_id: household.id, name: "Movies")
    [ [ "2", "Severance", "Episode", 30.minutes, {} ], [ "5", "Movies", "Movie", 2.hours, { "library_ids" => [ movies_library.id ] } ] ]
      .each do |number, name, type, length, narrower|
      station = Station.create!(household_id: household.id, number: number, name: name, snap_minutes: 30)
      block = station.station_blocks.create!(layer: "base", source: { "kinds" => [ type.downcase ] }.merge(narrower), ordering: "sequential")
      # In an order that's the same every run (ids made in the same
      # millisecond aren't), the files Playwright's Chromium can play first:
      # what's on now is the first of them.
      paths = MediaFile.unscoped.where(household_id: household.id).pluck(:id, :path).to_h
      candidates = Stations::Source.candidates(household.id, block.source)
        .sort_by { |candidate| [ paths[candidate.media_file_id].to_s.end_with?(".webm") ? 0 : 1, paths[candidate.media_file_id].to_s ] }
      starts = 1.hour.ago.beginning_of_hour
      (0...((6.hours / length).ceil)).each do |index|
        candidate = candidates[index % candidates.size]
        Airing.create!(household_id: household.id, station: station, station_block: block, playable_type: candidate.playable_type,
          playable_id: candidate.playable_id, media_file_id: candidate.media_file_id, series_key: candidate.series_key,
          starts_at: starts + (index * length), ends_at: starts + ((index + 1) * length), reason: "The channel's mix · next in order")
      end
    end

    seed_playback_page(household)

    # Someone to search for and visit.
    pacino = Person.find_or_create_by!(tmdb_id: 1158) { |person| person.name = "Al Pacino" }
    heat.credits.create!(person: pacino, role: "cast", character: "Vincent Hanna")
  end

  # The Playback page (frontend/e2e/playback-page.spec.ts): a play that
  # failed, and optimized versions in every state, on Corpus files. Optimizing
  # is paused, so the run's transcoder never encodes one and changes how a
  # Corpus case plays; the ready one has no file, so nothing plays it.
  def seed_playback_page(household)
    setting = AppSetting.current
    setting.update!(optimize_paused: true)
    corpus = ->(title) { Movie.unscoped.find_by!(household_id: household.id, title: title).media_files.first }

    mpeg2 = corpus.call("Case MPEG2 TS")
    failed = PlaybackSession.create!(household_id: household.id, profile: Profile.default_for(household), playable: mpeg2.editions.first.playable,
      media_file: mpeg2, method: "video_transcode", state: "ended", device_name: "Harness TV", started_at: 1.hour.ago, last_seen_at: 1.hour.ago,
      transcode_error: "ffmpeg exited 1: Conversion failed!",
      decision: { "method" => "video_transcode", "summary" => "MPEG-2 video isn't supported here — converted to H.264 576p",
                  "reasons" => [ "MPEG-2 video isn't supported here — converted to H.264 576p" ] })
    PlaybackEvent.create!(playback_session: failed, kind: "error", detail: { "message" => "MEDIA_ERR_SRC_NOT_SUPPORTED" }, position_seconds: 0.4)

    version = ->(title, **attributes) { OptimizedVersion.create!(household_id: household.id, media_file: corpus.call(title), **attributes) }
    version.call("Case DTS", reason: "all_devices")
    version.call("Case TrueHD", reason: "airing", needed_at: 2.hours.from_now)
    version.call("Case FLAC", origin: "manual", reason: "manual")
    # Never stale to the run's transcoder, which would otherwise take it back.
    version.call("Case Hi10P", state: "encoding", progress: 0.42, worker: "e2e", encoder: "software", reason: "all_devices",
      started_at: 10.minutes.ago, heartbeat_at: 1.day.from_now)
    version.call("Case MKV AC3 Subs", state: "failed", attempts: 3, reason: "all_devices", error: "ffmpeg exited 1: Invalid data found")
    version.call("Case MovText", state: "ready", size: 120.megabytes, height: 1080, reason: "all_devices",
      started_at: 2.days.ago - 20.minutes, finished_at: 2.days.ago)
    version.call("Case AV1 Opus", state: "skipped", origin: "manual")
  end

  # The playback benchmark (frontend/e2e/bench.spec.ts, BENCH=1): six
  # minutes of 1080p at a real film's bitrate — noise keeps the encoder
  # honest — so segments are the size they are at home, not the corpus's
  # two seconds of test card. One file per path Chrome takes: repackaged,
  # sound converted, picture converted. Made once and kept in tmp.
  BENCH = {
    "Bench Remux" => "remux.mkv",
    "Bench Audio" => "audio.mkv",
    "Bench Convert" => "convert.mkv"
  }.freeze

  def seed_bench(root)
    fixtures = Rails.root.join("tmp", "e2e-fixtures", "bench")
    FileUtils.mkdir_p(fixtures)
    base = fixtures.join("remux.mkv")
    source = %w[-f lavfi -i testsrc2=size=1920x1080:rate=24:duration=360,noise=alls=12:allf=t -f lavfi -i sine=frequency=440:duration=360]
    unless base.file?
      # A keyframe every 5 s, as a Blu-ray remux has roughly.
      ToolRunner.run(%w[ffmpeg -v error -y] + source + %W[-c:v libx264 -preset ultrafast -b:v 8M -maxrate 10M -bufsize 16M
        -g 120 -keyint_min 120 -sc_threshold 0 -c:a aac -b:a 192k -shortest #{base}], timeout: 1800)
    end
    audio = fixtures.join("audio.mkv")
    unless audio.file?
      ToolRunner.run(%W[ffmpeg -v error -y -i #{base} -map 0:v -map 0:a -c:v copy -c:a ac3 -ac 6 -b:a 448k #{audio}], timeout: 600)
    end
    convert = fixtures.join("convert.mkv")
    unless convert.file?
      ToolRunner.run(%W[ffmpeg -v error -y -i #{base} -map 0:v -map 0:a -c:v mpeg2video -b:v 12M -maxrate 15M -bufsize 8M -g 12
        -c:a copy #{convert}], timeout: 1800)
    end
    BENCH.each do |title, fixture|
      target = root.join("bench", "#{title} (2000)", "#{title} (2000).mkv")
      FileUtils.mkdir_p(target.dirname)
      FileUtils.cp(fixtures.join(fixture), target)
    end
  end

  # A channel whose programs change over while a spec watches (live.spec.ts):
  # laid from a few seconds from now, since the seed's own airings are laid
  # before the run starts. Back to back; a slot three seconds longer than
  # its file (the next starts early, not a slate); then a ten-second gap
  # (the slate, until the next starts). Prints the airings in order.
  # `e2e:transitions[clear]` takes the channel away again — and, since
  # watching live counts as watched, puts the episodes' watch state back as
  # it was, for the specs that read the seed after it.
  TRANSITIONS_NUMBER = "7"
  TRANSITIONS_STATE = Rails.root.join("tmp", "e2e-transitions-watch-states.json")

  desc "Lay (or clear) the harness's program-change channel, starting a few seconds from now"
  task :transitions, [ :clear ] => :environment do |_task, args|
    household = Household.find_by!(name: HOUSEHOLD_NAME)
    episodes = Episode.unscoped.joins(:show).where(shows: { household_id: household.id }).includes(:show, editions: :media_file).to_a
      .select { |episode| episode.editions.first&.media_file&.path.to_s.end_with?(".webm") }
    states = WatchState.unscoped.where(playable_type: "Episode", playable_id: episodes.map(&:id))
    Station.unscoped.where(household_id: household.id, number: TRANSITIONS_NUMBER).find_each do |station|
      PlaybackSession.unscoped.where(airing_id: Airing.unscoped.where(station_id: station.id).select(:id)).delete_all
      station.destroy
    end
    if TRANSITIONS_STATE.file?
      states.delete_all
      rows = JSON.parse(TRANSITIONS_STATE.read)
      WatchState.insert_all!(rows) if rows.any?
      TRANSITIONS_STATE.delete
    end
    next if args[:clear]

    TRANSITIONS_STATE.write(states.map(&:attributes).to_json)
    station = Station.create!(household_id: household.id, number: TRANSITIONS_NUMBER, name: "Changeover", snap_minutes: 0)
    pick = ->(show, number) { episodes.find { |episode| episode.show.title == show && episode.episode_number == number } }
    # [episode, seconds of slot past its file, seconds of gap before it]
    plan = [ [ pick.("Severance", 1), 0, 0 ], [ pick.("Severance", 2), 0, 0 ], [ pick.("Severance", 1), 3, 0 ],
      [ pick.("Severance", 2), 0, 0 ], [ pick.("Severance", 1), 0, 10 ] ]
    at = Time.current + 8.seconds
    airings = plan.map do |episode, longer, gap|
      file = episode.editions.first.media_file
      at += gap.seconds
      starts = at
      at += (file.duration_seconds + longer).seconds
      Airing.create!(household_id: household.id, station: station, playable: episode, media_file: file, series_key: episode.show_id,
        starts_at: starts, ends_at: at, reason: "Changeover")
    end
    puts(airings.map { |airing| { id: airing.id, title: airing.playable.show.title, starts_at: airing.starts_at.iso8601(3) } }.to_json)
  end

  desc "Remove the browser harness household"
  task clean: :environment do
    Household.where(name: HOUSEHOLD_NAME).find_each(&:destroy)
  end
end

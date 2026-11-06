# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "YouTube pull" do
  let(:household) { Household.create!(name: "Tube") }
  let(:root) { build_root }
  let(:library) { create_library(household: household, roots: root, kind: "channels", name: "YouTube").tap { |l| l.update!(download_root: root) } }
  let(:channel_id) { "UCy0tKL1T7wFoYcxCe0xjN6Q" }

  def channel_json(entries: [])
    { "_type" => "playlist", "channel" => "Technology Connections", "channel_id" => channel_id, "uploader_id" => "@TechnologyConnections",
      "description" => "Obscure tech.", "thumbnails" => [ { "id" => "avatar_uncropped", "url" => "https://yt3.ggpht.com/a" },
                                                             { "id" => "banner_uncropped", "url" => "https://yt3.googleusercontent.com/b" } ],
      "entries" => entries }
  end

  describe Youtube::Urls do
    it "rebuilds each kind of link from its id, and refuses anything that isn't YouTube" do
      expect(described_class.parse("youtube.com/@TechnologyConnections/videos").url).to eq("https://www.youtube.com/@TechnologyConnections")
      expect(described_class.parse("https://www.youtube.com/channel/#{channel_id}").url).to eq("https://www.youtube.com/channel/#{channel_id}")
      expect(described_class.parse("https://youtu.be/Ql7w1yX7hbI?t=10")).to have_attributes(kind: Youtube::Urls::Kind::Video,
        url: "https://www.youtube.com/watch?v=Ql7w1yX7hbI")
      expect(described_class.parse("https://m.youtube.com/shorts/Ql7w1yX7hbI").kind).to eq(Youtube::Urls::Kind::Video)
      expect(described_class.parse("https://www.youtube.com/playlist?list=PL1234567890abcdef").kind).to eq(Youtube::Urls::Kind::Playlist)
    end

    it "makes a live stream's link from a video's or a channel's, and refuses a playlist's" do
      expect(described_class.live_url("https://www.youtube.com/live/rFZHOHl-L8A?si=x")).to eq("https://www.youtube.com/watch?v=rFZHOHl-L8A")
      expect(described_class.live_url("youtube.com/@LofiGirl/live")).to eq("https://www.youtube.com/@LofiGirl/live")
      expect(described_class.live_url("https://www.youtube.com/channel/#{channel_id}")).to eq("https://www.youtube.com/channel/#{channel_id}/live")
      expect { described_class.live_url("https://www.youtube.com/playlist?list=PL1234567890abcdef") }.to raise_error(Youtube::Urls::Invalid)

      [ "https://vimeo.com/123", "http://192.168.1.1/@x", "https://www.youtube.com/watch?v=short", "javascript:alert(1)",
        "https://www.youtube.com/@a/../../x" ].each do |bad|
        expect { described_class.parse(bad) }.to raise_error(Youtube::Urls::Invalid), bad
      end
    end
  end

  describe Youtube::Tracker do
    before { library }

    it "tracks a channel in a folder named for it, and the first poll backfills the newest N" do
      allow(Youtube::YtDlp).to receive(:json).with("https://www.youtube.com/@TechnologyConnections/videos", anything)
        .and_return(channel_json)
      preview = Youtube::Resolver.resolve(Youtube::Urls.parse("youtube.com/@TechnologyConnections"))

      channel = described_class.new(household).track(preview, backfill: "recent", backfill_count: 2, keep_last: 5)

      expect(channel).to have_attributes(folder: "Technology Connections", youtube_id: channel_id, handle: "@TechnologyConnections",
        tracked: true, backfill_count: 2, keep_last: 5, avatar_url: "https://yt3.ggpht.com/a")
      expect(enqueued_jobs.map { |job| job["job_class"] }).to include("PollChannelJob", "SyncArtworkJob")

      entries = %w[aaaaaaaaaaa bbbbbbbbbbb].map { |id| { "id" => id, "title" => "Video #{id[0]}" } }
      expect(Youtube::YtDlp).to receive(:json).with("https://www.youtube.com/channel/#{channel_id}/videos", [ "--flat-playlist", "--playlist-end", "2" ])
        .and_return(channel_json(entries: entries))
      Youtube::Poller.new(channel).call

      expect(channel.youtube_downloads.pluck(:youtube_id, :state)).to contain_exactly([ "aaaaaaaaaaa", "queued" ], [ "bbbbbbbbbbb", "queued" ])
      expect(channel.reload.last_polled_at).to be_present

      # Later polls queue only what's newer than the newest known video,
      # never the older ones the backfill left behind.
      older = %w[ddddddddddd eeeeeeeeeee].map { |id| { "id" => id, "title" => "Old #{id[0]}" } }
      expect(Youtube::YtDlp).to receive(:json).with(anything, [ "--flat-playlist", "--playlist-end", "50" ])
        .and_return(channel_json(entries: [ { "id" => "ccccccccccc", "title" => "New" } ] + entries + older))
      Youtube::Poller.new(channel).call
      expect(channel.youtube_downloads.pluck(:youtube_id)).to contain_exactly("aaaaaaaaaaa", "bbbbbbbbbbb", "ccccccccccc")
    end

    it "takes over a folder of the channel's name put there by hand, rather than starting a second channel beside it" do
      by_hand = Channel.create!(household: household, library: library, folder: "Technology Connections", title: "Technology Connections")
      claimed = Channel.create!(household: household, library: library, folder: "TC", title: "TC", youtube_id: "UC#{'x' * 22}")
      allow(Youtube::YtDlp).to receive(:json).and_return(channel_json)
      preview = Youtube::Resolver.resolve(Youtube::Urls.parse("youtube.com/@TechnologyConnections"))

      channel = described_class.new(household).track(preview)

      expect(channel.id).to eq(by_hand.id)
      expect(channel).to have_attributes(folder: "Technology Connections", youtube_id: channel_id, handle: "@TechnologyConnections",
        avatar_url: "https://yt3.ggpht.com/a", tracked: true)
      expect(Channel.where(library: library).count).to eq(2)

      # A folder another channel's id already claimed is not up for taking.
      claimed.update!(folder: "Other Channel")
      allow(Youtube::YtDlp).to receive(:json).and_return(channel_json.merge("channel" => "Other Channel", "channel_id" => "UC#{'y' * 22}"))
      other = described_class.new(household).track(Youtube::Resolver.resolve(Youtube::Urls.parse("youtube.com/@Other")))
      expect(other).to have_attributes(folder: "Other Channel [UC#{'y' * 22}]")
      expect(claimed.reload.youtube_id).to eq("UC#{'x' * 22}")
    end

    it "fetches only videos whose titles match the channel's filter, looking back far enough for the newest N that do" do
      channel = Channel.create!(household: household, library: library, folder: "TC", title: "TC", youtube_id: channel_id, tracked: true,
        backfill: "recent", backfill_count: 2, title_filter: "^full episode|\\bpart \\d+")
      entries = [ [ "aaaaaaaaaaa", "Trailer" ], [ "bbbbbbbbbbb", "FULL EPISODE: Dishwashers" ], [ "ccccccccccc", "Behind the scenes" ],
                  [ "ddddddddddd", "Toasters, Part 2" ], [ "eeeeeeeeeee", "Full episode: Toasters" ] ]
        .map { |id, title| { "id" => id, "title" => title } }
      expect(Youtube::YtDlp).to receive(:json).with(anything, [ "--flat-playlist", "--playlist-end", "500" ])
        .and_return(channel_json(entries: entries))
      Youtube::Poller.new(channel).call
      expect(channel.youtube_downloads.pluck(:youtube_id)).to contain_exactly("bbbbbbbbbbb", "ddddddddddd")

      # Later polls hold to it too, and what it passed over isn't recorded.
      newer = [ { "id" => "fffffffffff", "title" => "Q&A" }, { "id" => "ggggggggggg", "title" => "Full Episode: Kettles" } ]
      expect(Youtube::YtDlp).to receive(:json).with(anything, [ "--flat-playlist", "--playlist-end", "50" ])
        .and_return(channel_json(entries: newer + entries))
      Youtube::Poller.new(channel).call
      expect(channel.youtube_downloads.pluck(:youtube_id)).to contain_exactly("bbbbbbbbbbb", "ddddddddddd", "ggggggggggg")
    end

    it "refuses a title filter that isn't a pattern, and gives up on one that runs away" do
      channel = Channel.new(household: household, library: library, folder: "TC", title: "TC", title_filter: "part (\\d+")
      expect(channel).not_to be_valid
      expect(channel.errors[:title_filter].join).to include("isn't a pattern")

      channel.title_filter = "  "
      expect(channel).to be_valid
      expect(channel.title_filter).to be_nil
      expect(channel.wants_title?("Anything")).to be(true)

      # A backreference keeps Ruby from making this one linear: it runs out
      # of time rather than finishing.
      channel.title_filter = "^(a|a)*\\1$"
      expect { channel.send(:title_pattern).match?("#{'a' * 40}b") }.to raise_error(Regexp::TimeoutError)
      expect(channel.wants_title?("#{'a' * 40}b")).to be(false)
    end

    it "records a failed poll on the channel, where the admin page shows it" do
      channel = Channel.create!(household: household, library: library, folder: "TC", title: "TC", youtube_id: channel_id, tracked: true)
      allow(Youtube::YtDlp).to receive(:json).and_raise(Youtube::YtDlp::Error, "Sign in to confirm you're not a bot")
      Youtube::Poller.new(channel).call
      expect(channel.reload.last_poll_error).to eq("Sign in to confirm you're not a bot")
    end

    it "downloads a pasted video into its channel, kept, and fetches it again only if it isn't there" do
      library
      video = { "id" => "Ql7w1yX7hbI", "title" => "Dishwashers", "channel_id" => channel_id }
      preview = Youtube::Resolver::Preview.new(kind: Youtube::Urls::Kind::Video, url: "https://www.youtube.com/watch?v=Ql7w1yX7hbI",
        channel: Youtube::Resolver.channel_info(channel_json), videos: [ video ])
      tracker = described_class.new(household)

      row = tracker.download(preview).sole
      expect(row).to have_attributes(state: "queued", kept: true, by_hand: true)
      expect(row.channel).to have_attributes(title: "Technology Connections", tracked: false)

      row.update!(state: "done", path: "/x.mp4")
      expect { tracker.download(preview) }.not_to have_enqueued_job(DownloadVideoJob)
      expect(row.reload.state).to eq("done")

      row.update!(state: "removed", kept: false)
      expect { tracker.download(preview) }.to have_enqueued_job(DownloadVideoJob).with(row.id)
      expect(row.reload).to have_attributes(state: "queued", kept: true, attempts: 0)

      # One put there by hand is already the video.
      other = video.merge("id" => "aaaaaaaaaaa")
      Video.create!(household: household, library: library, channel: row.channel, title: "Mine", youtube_id: "aaaaaaaaaaa", source: "info_json")
      expect(tracker.download(preview.with(videos: [ other ]))).to be_empty
    end

    it "refuses to track anything until a download folder is set" do
      library.update!(download_root: nil)
      expect { described_class.new(household) }.to raise_error(Youtube::Tracker::NoDownloadFolder)
    end
  end

  # The one library Stream writes into (CLAUDE.md, media invariant 1): the
  # YouTube download folder, with only files it fetched itself.
  describe Youtube::Downloader, :changes_library_root do
    let(:channel) { Channel.create!(household: household, library: library, folder: "TC", title: "TC", youtube_id: channel_id, max_height: 720) }
    let(:download) { YoutubeDownload.create!(household: household, channel: channel, youtube_id: "Ql7w1yX7hbI", title: "Dishwashers") }

    it "asks for a format that plays as it is, into the channel's folder, then scans that folder" do
      path = File.join(root, "TC", "20240131 - Dishwashers [Ql7w1yX7hbI].mp4")
      expect(Youtube::YtDlp).to receive(:download) do |url, args|
        expect(url).to eq("https://www.youtube.com/watch?v=Ql7w1yX7hbI")
        expect(args.each_cons(2).to_a).to include([ "--paths", "home:#{File.join(root, 'TC')}" ], [ "--merge-output-format", "mp4/webm/mkv" ])
        expect(args[args.index("-f") + 1]).to start_with("bv*[vcodec^=avc1][height<=720]+ba[acodec^=mp4a]")
          .and include("bv*[height<=720]+ba[acodec=opus]/bv*[height<=720]+ba")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "video")
        ToolRunner::Result.new(status: 0, stdout: "#{path}\n", stderr: "")
      end

      described_class.new(download).call

      expect(download.reload).to have_attributes(state: "done", path: path, bytes: 5, attempts: 1)
      expect(enqueued_jobs.find { |job| job["job_class"] == "ScanLibraryJob" }["arguments"]).to eq([ library.id, File.join(root, "TC") ])
    end

    it "starts each try in an empty scratch folder, so a cut-off format from a failed try isn't merged as if whole" do
      temp = nil
      allow(Youtube::YtDlp).to receive(:download) do |_url, args|
        temp = args[args.index { |arg| arg.start_with?("temp:") }].delete_prefix("temp:")
        File.write(File.join(temp, "Dishwashers [Ql7w1yX7hbI].f137.mp4"), "first minute")
        raise Youtube::YtDlp::Error, "HTTP Error 403"
      end
      DownloadVideoJob.perform_now(download.id)
      expect(Dir.exist?(temp)).to be(false)

      FileUtils.mkdir_p(temp)
      File.write(File.join(temp, "Dishwashers [Ql7w1yX7hbI].f137.mp4"), "first minute")
      expect(Youtube::YtDlp).to receive(:download) do
        expect(Dir.children(temp)).to be_empty
        ToolRunner::Result.new(status: 0, stdout: "", stderr: "does not pass filter")
      end
      DownloadVideoJob.perform_now(download.id)
    end

    it "marks a video a rule refused as skipped, not failed" do
      allow(Youtube::YtDlp).to receive(:download).and_return(ToolRunner::Result.new(status: 0, stdout: "", stderr: "does not pass filter (live_status!=is_live)"))
      described_class.new(download).call
      expect(download.reload).to have_attributes(state: "skipped", reason: "A livestream")
    end

    it "fetches a video again over the file it left, and takes away the old copy when the name changed" do
      folder = File.join(root, "TC")
      old = File.join(folder, "20240131 - Dishwashrs [Ql7w1yX7hbI].mp4")
      FileUtils.mkdir_p(folder)
      %w[.mp4 .info.json .jpg].each { |ext| File.write(old.sub(".mp4", ext), "old") }
      download.update!(state: "done", path: old)
      fresh = File.join(folder, "20240131 - Dishwashers [Ql7w1yX7hbI].mp4")
      expect(Youtube::YtDlp).to receive(:download) do |_url, args|
        expect(args).to include("--force-overwrites")
        expect(args).not_to include("--no-overwrites")
        %w[.mp4 .info.json .jpg].each { |ext| File.write(fresh.sub(".mp4", ext), "fresh") }
        ToolRunner::Result.new(status: 0, stdout: "#{fresh}\n", stderr: "")
      end

      download.fetch_again!
      DownloadVideoJob.perform_now(download.id)

      expect(download.reload).to have_attributes(state: "done", path: fresh, by_hand: true)
      expect(Dir.children(folder).sort).to eq([ "20240131 - Dishwashers [Ql7w1yX7hbI].info.json", "20240131 - Dishwashers [Ql7w1yX7hbI].jpg",
        "20240131 - Dishwashers [Ql7w1yX7hbI].mp4" ])
    end

    it "keeps the new sidecars when only the container changed" do
      folder = File.join(root, "TC")
      old = File.join(folder, "Dishwashers [Ql7w1yX7hbI].mkv")
      FileUtils.mkdir_p(folder)
      File.write(old, "old")
      download.update!(state: "done", path: old)
      fresh = old.sub(".mkv", ".mp4")
      allow(Youtube::YtDlp).to receive(:download) do
        [ fresh, fresh.sub(".mp4", ".info.json") ].each { |file| File.write(file, "fresh") }
        ToolRunner::Result.new(status: 0, stdout: "#{fresh}\n", stderr: "")
      end

      download.fetch_again!
      DownloadVideoJob.perform_now(download.id)

      expect(Dir.children(folder).sort).to eq([ "Dishwashers [Ql7w1yX7hbI].info.json", "Dishwashers [Ql7w1yX7hbI].mp4" ])
    end

    it "fetches a video someone asked for whatever the channel's rules say" do
      channel.update!(skip_live: true, backfill: "since", backfill_since: Date.new(2025, 1, 1))
      expect(described_class.new(download).args("/x")).to include("--match-filters", "--dateafter")
      download.update!(by_hand: true)
      expect(described_class.new(download).args("/x")).not_to include("--match-filters", "--dateafter")
    end

    it "retries a failed download later, then gives up and says so" do
      allow(Youtube::YtDlp).to receive(:download).and_raise(Youtube::YtDlp::Error, "HTTP Error 403")
      DownloadVideoJob.perform_now(download.id)
      expect(download.reload).to have_attributes(state: "queued", attempts: 1, last_error: "HTTP Error 403")

      download.update!(attempts: YoutubeDownload::MAX_ATTEMPTS - 1)
      DownloadVideoJob.perform_now(download.id)
      expect(download.reload.state).to eq("failed")
      expect(ActivityEntry.last.summary).to include("Couldn't download Dishwashers")
    end
  end

  describe Youtube::Retention, :changes_library_root do
    it "deletes Stream's own downloads beyond the newest N, with their sidecars, but not one being watched" do
      channel = Channel.create!(household: household, library: library, folder: "TC", title: "TC", youtube_id: channel_id, keep_last: 1)
      profile = Profile.default_for(household)
      rows = { "aaaaaaaaaaa" => 2022, "bbbbbbbbbbb" => 2023, "ccccccccccc" => 2024 }.map do |id, year|
        path = File.join(root, "TC", "#{year} [#{id}].mp4")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "v")
        File.write(path.sub(".mp4", ".info.json"), "{}")
        File.write(path.sub(".mp4", ".en.vtt"), "WEBVTT")
        Video.create!(household: household, library: library, channel: channel, title: id, youtube_id: id, upload_date: Date.new(year),
          source: "info_json")
        YoutubeDownload.create!(household: household, channel: channel, youtube_id: id, state: "done", path: path)
      end
      WatchState.create!(profile: profile, playable: Video.find_by(youtube_id: "aaaaaaaaaaa"), position_seconds: 300, duration_seconds: 600,
        last_watched_at: Time.current)
      File.write(File.join(root, "TC", "mine.mp4"), "not Stream's")

      described_class.new(channel).call

      expect(rows.map { |row| row.reload.state }).to eq(%w[done removed done])
      expect(Dir.children(File.join(root, "TC")).sort).to eq([ "2022 [aaaaaaaaaaa].en.vtt", "2022 [aaaaaaaaaaa].info.json",
        "2022 [aaaaaaaaaaa].mp4", "2024 [ccccccccccc].en.vtt", "2024 [ccccccccccc].info.json", "2024 [ccccccccccc].mp4", "mine.mp4" ])
    end

    it "passes by a download marked to keep, which doesn't count towards the N" do
      channel = Channel.create!(household: household, library: library, folder: "TC", title: "TC", youtube_id: channel_id, keep_last: 1)
      rows = { "aaaaaaaaaaa" => 2022, "bbbbbbbbbbb" => 2023, "ccccccccccc" => 2024 }.map do |id, year|
        path = File.join(root, "TC", "#{year} [#{id}].mp4")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "v")
        Video.create!(household: household, library: library, channel: channel, title: id, youtube_id: id, upload_date: Date.new(year),
          source: "info_json")
        YoutubeDownload.create!(household: household, channel: channel, youtube_id: id, state: "done", path: path, kept: year == 2022)
      end

      described_class.new(channel).call

      expect(rows.map { |row| row.reload.state }).to eq(%w[done removed done])
    end

    it "takes only the sidecars yt-dlp wrote, and nothing a row points at outside the folder" do
      channel = Channel.create!(household: household, library: library, folder: "TC", title: "TC", youtube_id: channel_id, keep_last: 1)
      folder = File.join(root, "TC")
      FileUtils.mkdir_p(folder)
      newest = File.join(folder, "New [ccccccccccc].mp4")
      File.write(newest, "x")
      YoutubeDownload.create!(household: household, channel: channel, youtube_id: "ccccccccccc", state: "done", path: newest)
      { "ccccccccccc" => 2025, "aaaaaaaaaaa" => 2020, "bbbbbbbbbbb" => 2019 }.each do |id, year|
        Video.create!(household: household, library: library, channel: channel, title: id, youtube_id: id, upload_date: Date.new(year),
          source: "info_json")
      end
      video = File.join(folder, "Talk [aaaaaaaaaaa].mp4")
      %w[.mp4 .info.json .webp .en-US.vtt].each { |ext| File.write(video.sub(".mp4", ext), "x") }
      # Someone else's files that happen to start the same way.
      File.write(File.join(folder, "Talk [aaaaaaaaaaa] notes.nfo"), "mine")
      File.write(File.join(folder, "Talk [aaaaaaaaaaa].mp4.bak.jpg"), "mine")
      YoutubeDownload.create!(household: household, channel: channel, youtube_id: "aaaaaaaaaaa", state: "done", path: video)
      elsewhere = File.join(build_root, "Precious [bbbbbbbbbbb].mp4")
      File.write(elsewhere, "not in the download folder")
      stray = YoutubeDownload.create!(household: household, channel: channel, youtube_id: "bbbbbbbbbbb", state: "done", path: elsewhere)

      described_class.new(channel).call

      expect(Dir.children(folder).sort).to eq([ "New [ccccccccccc].mp4", "Talk [aaaaaaaaaaa] notes.nfo", "Talk [aaaaaaaaaaa].mp4.bak.jpg" ])
      expect(File).to exist(elsewhere)
      expect(stray.reload.state).to eq("done")
    end
  end

  # The real argv, built by YtDlp itself: only ToolRunner is stood in for.
  describe Youtube::YtDlp do
    def ran
      argvs = []
      allow(ToolRunner).to receive(:run) do |argv, **|
        argvs << argv
        ToolRunner::Result.new(status: 0, stdout: { "id" => "Ql7w1yX7hbI" }.to_json, stderr: "")
      end
      yield
      argvs
    end

    it "runs with its own config only, and always ends options before the URL" do
      url = Youtube::Urls.parse("https://youtu.be/Ql7w1yX7hbI").url
      argvs = ran do
        described_class.json(url, %w[--flat-playlist])
        described_class.download(url, %w[-f best -o %(title)s.%(ext)s])
      end

      expect(argvs).to all(start_with([ "yt-dlp", "--ignore-config", "--no-warnings", "--no-progress" ]))
      expect(argvs.map { |argv| argv.last(2) }).to all(eq([ "--", url ]))
      expect(argvs.first).to include("--dump-single-json", "--flat-playlist")
    end

    it "asks for only the fields of a video it reads: the whole answer can run past what ToolRunner keeps" do
      url = "https://www.youtube.com/watch?v=Ql7w1yX7hbI"
      argvs = ran { expect(described_class.video(url)).to eq("id" => "Ql7w1yX7hbI") }

      template = argvs.sole[argvs.sole.index("--print") + 1]
      expect(template).to start_with("%(.{id,title,").and end_with("})j")
      expect(template).not_to include("formats", "captions")
      expect(argvs.sole).to include("--no-playlist").and(end_with([ "--", url ]))
      expect(argvs.sole).not_to include("--dump-single-json")
    end

    it "prefers the copy it keeps up to date" do
      storage = Dir.mktmpdir
      stub_const("ENV", ENV.to_h.merge("STREAM_STORAGE_DIR" => storage))
      described_class.managed_path.dirname.mkpath
      described_class.managed_path.write("#!/bin/sh\n")
      described_class.managed_path.chmod(0o755)

      argvs = ran { described_class.json("https://www.youtube.com/watch?v=Ql7w1yX7hbI") }

      expect(argvs.sole.first).to eq(described_class.managed_path.to_s)
    ensure
      FileUtils.rm_rf(storage)
    end

    it "reports yt-dlp's own error line, and a non-object answer" do
      allow(ToolRunner).to receive(:run).and_return(ToolRunner::Result.new(status: 1, stdout: "",
        stderr: "WARNING: old\nERROR: [youtube] Ql7w1yX7hbI: Video unavailable\n"))
      expect { described_class.json("https://www.youtube.com/watch?v=Ql7w1yX7hbI") }
        .to raise_error(described_class::Error, "[youtube] Ql7w1yX7hbI: Video unavailable")

      allow(ToolRunner).to receive(:run).and_return(ToolRunner::Result.new(status: 0, stdout: "[1, 2]", stderr: ""))
      expect { described_class.json("https://www.youtube.com/watch?v=Ql7w1yX7hbI") }.to raise_error(described_class::Error, /isn't an object/)

      allow(ToolRunner).to receive(:run).and_raise(ToolRunner::Timeout, "yt-dlp timed out")
      expect { described_class.download("https://www.youtube.com/watch?v=Ql7w1yX7hbI", []) }.to raise_error(described_class::Error, /timed out/)
    end
  end
end

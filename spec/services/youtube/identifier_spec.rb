# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Identifying hand-placed YouTube videos" do
  let(:household) { Household.create!(name: "Haus") }
  let(:root) { build_root }
  let(:library) { create_library(household: household, roots: root, kind: "channels", name: "YouTube").tap { |l| l.update!(download_root: root) } }
  let(:channel_id) { "UCboMX_UNgaPBsUOIgasn3-Q" }
  let(:channel) { Channel.create!(household: household, library: library, folder: "Funhaus", title: "Funhaus", youtube_id: channel_id) }

  # A video filed from a file of this name and length, as the scan would.
  def placed(name, length, in_channel: channel)
    Video.create!(household: household, library: library, channel: in_channel, title: name, source: "folder").tap do |video|
      file = MediaFile.create!(household: household, library: library, path: File.join(root, in_channel.folder, "#{name}.mp4"), size: 1,
        mtime: Time.current, state: "probed", duration_seconds: length)
      video.editions.create!(media_file: file)
    end
  end

  def entry(id, title, duration) = { "id" => id, "title" => title, "duration" => duration }

  def listing(videos: [], streams: [], shorts: [])
    allow(Youtube::YtDlp).to receive(:json) do |url, _args|
      case url
      when %r{/videos\z} then { "channel_id" => channel_id, "channel" => "Funhaus", "entries" => videos,
                                 "thumbnails" => [ { "id" => "avatar_uncropped", "url" => "https://yt3.ggpht.com/av" } ] }
      when %r{/streams\z} then { "entries" => streams }
      when %r{/shorts\z} then { "entries" => shorts }
      else raise "unexpected #{url}"
      end
    end
  end

  def hydrations = enqueued_jobs.select { |job| job["job_class"] == "HydrateVideoJob" }.map { |job| job["arguments"].first }

  describe Youtube::Identifier do
    it "takes only a sure match, and leaves the closest few for a person otherwise" do
      aladdin = placed("ALADDIN ME - Demo Disk Gameplay", 1076.27)
      # yt-dlp's file names hold full-width stand-ins for what they can't.
      smarter = placed("Are You Smarter Than a YouTuber？ - Demo Disk Gameplay w⧸ Bruce", 900.4)
      retitled = placed("Ryan's Backyard Boxing Match", 1200.0)
      wrong_length = placed("BIG BALLERS - Demo Disk Gameplay", 300.0)
      twice = placed("Funhaus Feud", 600.0)
      porno = placed("STAR WARS PORNO - Demo Disk Gameplay", 700.0)
      members = placed("A Very Personal Funhaus Feud Bonus Round (Members Only!)", 500.0)
      listing(
        videos: [
          entry("aaaaaaaaaaa", "ALADDIN ME - Demo Disk Gameplay", 1076),
          entry("bbbbbbbbbbb", "Are You Smarter Than a YouTuber? - Demo Disk Gameplay w/ Bruce", 900),
          entry("ccccccccccc", "Ryan's Backyard Boxing Match!", 1201),
          entry("ddddddddddd", "BIG BALLERS - Demo Disk Gameplay", 1500),
          entry("eeeeeeeeeee", "Funhaus Feud", 600), entry("fffffffffff", "Funhaus Feud", 611),
          entry("ggggggggggg", "STAR WARS JESUS - Demo Disk Gameplay", 845)
        ],
        streams: [ entry("hhhhhhhhhhh", "Dude Soup Live", 7200) ]
      )

      counts = described_class.new(channel).call

      expect(counts.serialize).to eq("identified" => 3, "needs_review" => 3, "not_found" => 1)
      expect(aladdin.reload).to have_attributes(youtube_id: "aaaaaaaaaaa", identity: "identified",
        url: "https://www.youtube.com/watch?v=aaaaaaaaaaa")
      expect(smarter.reload.youtube_id).to eq("bbbbbbbbbbb")
      expect(retitled.reload.youtube_id).to eq("ccccccccccc")
      expect(hydrations).to contain_exactly(aladdin.id, smarter.id, retitled.id)

      # The right title at the wrong length; one title twice on the channel;
      # 80% alike and a different video: a person's call, with reasons.
      expect(wrong_length.reload).to have_attributes(youtube_id: nil, identity: "needs_review")
      expect(wrong_length.youtube_candidates.first).to include("youtube_id" => "ddddddddddd", "reasons" => [ "title matches", "length differs by 1200s" ])
      expect(twice.reload.youtube_candidates.map { |c| c["youtube_id"] }).to eq(%w[eeeeeeeeeee fffffffffff])
      expect(porno.reload).to have_attributes(identity: "needs_review")
      expect(porno.youtube_candidates.first).to include("youtube_id" => "ggggggggggg")
      expect(porno.youtube_candidates.first.keys).to contain_exactly("youtube_id", "title", "duration_seconds", "score", "reasons")
      expect(members.reload).to have_attributes(identity: "not_found", youtube_candidates: [])

      # The listing brought the channel's picture, and nothing is asked twice.
      expect(channel.reload.avatar_url).to eq("https://yt3.ggpht.com/av")
      expect(Youtube::YtDlp).to have_received(:json).exactly(3).times
      expect(described_class.new(channel).call.serialize).to eq("identified" => 0, "needs_review" => 0, "not_found" => 0)
      expect(Youtube::YtDlp).to have_received(:json).exactly(3).times
    end

    it "never offers a video another file already is, and gives up only the tabs a channel lacks" do
      placed("Toasters", 300.0).update!(youtube_id: "aaaaaaaaaaa", identity: "identified")
      copy = placed("Toasters ", 300.0)
      allow(Youtube::YtDlp).to receive(:json) do |url, _args|
        raise Youtube::YtDlp::Error, "This channel does not have a shorts tab" if url.end_with?("/shorts")

        { "entries" => url.end_with?("/videos") ? [ entry("aaaaaaaaaaa", "Toasters", 300) ] : [] }
      end

      described_class.new(channel).call
      expect(copy.reload).to have_attributes(youtube_id: nil, identity: "not_found")

      allow(Youtube::YtDlp).to receive(:json).and_raise(Youtube::YtDlp::Error, "Sign in to confirm you're not a bot")
      later = placed("Kettles", 100.0)
      IdentifyChannelVideosJob.perform_now(channel.id)
      expect(later.reload.identity).to eq("unchecked")
      expect(ActivityEntry.where(event: "channel.identify_failed").sole.summary).to include("not a bot")
    end

    it "looks before the first backfill, so what's on disk isn't fetched again" do
      aladdin = placed("ALADDIN ME - Demo Disk Gameplay", 1076.0)
      channel.update!(tracked: true, backfill: "all")
      listing(videos: [ entry("aaaaaaaaaaa", "ALADDIN ME - Demo Disk Gameplay", 1076), entry("bbbbbbbbbbb", "New one", 60) ])

      Youtube::Poller.new(channel).call

      expect(aladdin.reload.youtube_id).to eq("aaaaaaaaaaa")
      expect(channel.youtube_downloads.pluck(:youtube_id)).to eq([ "bbbbbbbbbbb" ])
    end

    it "is asked of every channel YouTube knows with videos still waiting, hourly" do
      placed("Waiting", 10.0)
      folder_only = Channel.create!(household: household, library: library, folder: "Mystery", title: "Mystery")
      placed("Also waiting", 10.0, in_channel: folder_only)

      IdentifyVideosJob.perform_now

      expect(enqueued_jobs.select { |job| job["job_class"] == "IdentifyChannelVideosJob" }.map { |job| job["arguments"] }).to eq([ [ channel.id ] ])
    end
  end

  describe Youtube::Hydrator do
    let(:info) do
      { "id" => "aaaaaaaaaaa", "title" => "ALADDIN ME - Demo Disk Gameplay", "description" => "INT. WILLEMS HOUSE - DAY",
        "upload_date" => "20180730", "tags" => %w[funhaus demo], "webpage_url" => "https://www.youtube.com/watch?v=aaaaaaaaaaa",
        "chapters" => [ { "start_time" => 0, "end_time" => 60, "title" => "Intro" } ],
        "thumbnail" => "https://i.ytimg.com/vi_webp/aaaaaaaaaaa/maxresdefault.webp",
        "channel" => "Funhaus", "channel_id" => channel_id, "uploader_id" => "@Funhaus" }
    end

    it "fills in what an info.json would have said, and a rematch keeps it" do
      video = placed("ALADDIN ME - Demo Disk Gameplay", 1076.0)
      video.update!(youtube_id: "aaaaaaaaaaa", identity: "identified", locked_fields: [ "description" ])
      expect(Youtube::YtDlp).to receive(:video).with("https://www.youtube.com/watch?v=aaaaaaaaaaa").and_return(info)

      HydrateVideoJob.perform_now(video.id)

      expect(video.reload).to have_attributes(source: "youtube", upload_date: Date.new(2018, 7, 30), tags: %w[funhaus demo],
        description: nil, thumbnail_url: "https://i.ytimg.com/vi_webp/aaaaaaaaaaa/maxresdefault.webp")
      expect(video.chapters).to eq([ { "start" => 0.0, "end" => 60.0, "title" => "Intro" } ])
      file = video.media_files.sole
      expect(AnalysisRun.find_by!(media_file: file, step: "youtube_details").status).to eq("succeeded")
      expect(enqueued_jobs.map { |job| job["arguments"].first(2) }).to include([ "Video", video.id ])

      Catalog::VideoMatcher.new(file, library, Media::NameParser.parse("Funhaus/#{File.basename(file.path)}", Library::Kind::Channels),
        File.join(root, "Funhaus")).call
      expect(video.reload).to have_attributes(source: "youtube", upload_date: Date.new(2018, 7, 30), identity: "identified")
    end

    it "tells a folder's channel which YouTube channel it is, then looks up the rest of it" do
      folder = Channel.create!(household: household, library: library, folder: "Funhaus", title: "Funhaus")
      video = placed("ALADDIN ME - Demo Disk Gameplay", 1076.0, in_channel: folder)
      video.update!(youtube_id: "aaaaaaaaaaa", identity: "identified")
      allow(Youtube::YtDlp).to receive(:video).and_return(info)

      HydrateVideoJob.perform_now(video.id)

      expect(folder.reload).to have_attributes(youtube_id: channel_id, handle: "@Funhaus", url: "https://www.youtube.com/channel/#{channel_id}")
      expect(enqueued_jobs.map { |job| job["job_class"] }).to include("IdentifyChannelVideosJob")
    end

    it "records a video YouTube won't describe on the file, where Needs attention lists it" do
      video = placed("Members thing", 100.0)
      video.update!(youtube_id: "aaaaaaaaaaa", identity: "identified")
      allow(Youtube::YtDlp).to receive(:video).and_raise(Youtube::YtDlp::Error, "Join this channel to get access to members-only content")

      HydrateVideoJob.perform_now(video.id)

      run = AnalysisRun.find_by!(media_file: video.media_files.sole, step: "youtube_details")
      expect(run).to have_attributes(status: "failed", consecutive_failures: 1)
      expect(run.error).to include("members-only")
      expect(video.reload.source).to eq("folder")
    end
  end
end

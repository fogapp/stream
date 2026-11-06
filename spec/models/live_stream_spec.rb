# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe LiveStream do
  let(:household) { Household.create!(name: "Family") }
  let(:library) { Library.create!(household: household, name: "Cameras", kind: "live") }
  let(:unifi) { "rtsps://192.168.1.1:7441/AbCdEfGhIjKlMnOp?enableSrtp" }

  it "lives in a live library, which has no folders and is never scanned" do
    expect(library).to be_valid
    expect(Library.new(household: household, name: "X", kind: "live", roots: [ "/media" ])).not_to be_valid

    movies = create_library(household: household, roots: build_root)
    stream = described_class.new(household: household, library: movies, name: "Door", kind: "camera", url: unifi)
    expect(stream).not_to be_valid
    expect(stream.errors[:library]).to include("must be a live library")

    expect(Libraries::Scanner).not_to receive(:new)
    ScanLibraryJob.perform_now(library.id)
  end

  it "takes rtsp, rtsps, http and https addresses and nothing else" do
    %w[rtsp://cam/1 rtsps://cam:7441/x https://example.com/live.m3u8 http://10.0.0.2/stream.mpd].each do |url|
      expect(described_class.new(household: household, library: library, name: "A", kind: "web", url: url)).to be_valid
    end
    %w[file:///etc/passwd /media/movie.mkv udp://239.0.0.1:1234 rtsp://].each do |url|
      expect(described_class.new(household: household, library: library, name: "A", kind: "web", url: url)).not_to be_valid
    end
  end

  it "keeps the address encrypted and says only its scheme, host and port" do
    stream = described_class.create!(household: household, library: library, name: "Front door", kind: "camera", url: unifi)

    raw = ActiveRecord::Base.connection.select_value("SELECT url FROM live_streams WHERE id = #{ActiveRecord::Base.connection.quote(stream.id)}")
    expect(raw).not_to include("AbCdEfGhIjKlMnOp")
    expect(stream.source).to eq("rtsps://192.168.1.1:7441")
    expect(described_class.source_of("https://user:pw@example.com/live/index.m3u8")).to eq("https://example.com")
  end

  it "redacts every trace of the address from a tool's words" do
    stream = described_class.new(url: unifi)
    said = "[rtsp @ 0x1] #{unifi}: method DESCRIBE failed for /AbCdEfGhIjKlMnOp (AbCdEfGhIjKlMnOp)"

    redacted = stream.redact(said)
    expect(redacted).not_to include("AbCdEfGhIjKlMnOp")
    expect(redacted).to include("rtsps://192.168.1.1:7441: method DESCRIBE failed")

    with_password = described_class.new(url: "rtsp://admin:hunter22@10.0.0.9:554/live")
    expect(with_password.redact("401 for admin:hunter22 at rtsp://admin:hunter22@10.0.0.9:554/live")).to eq("401 for … at rtsp://10.0.0.9:554")
    # Short words in a path aren't secrets; replacing them would garble the message.
    expect(described_class.new(url: "https://example.com/live/index.m3u8").redact("live stream ended")).to eq("live stream ended")
  end

  it "keeps a YouTube link as the URL rebuilt from its id, a channel's as its live page, and shows it" do
    video = described_class.create!(household: household, library: library, name: "Lofi Girl", kind: "youtube",
      url: "youtu.be/rFZHOHl-L8A?si=shared&t=10")
    expect(video.url).to eq("https://www.youtube.com/watch?v=rFZHOHl-L8A")
    expect(video.source).to eq("youtube.com/watch?v=rFZHOHl-L8A")

    channel = described_class.new(household: household, library: library, name: "Lofi Girl", kind: "youtube", url: "https://www.youtube.com/@LofiGirl")
    expect(channel).to be_valid
    expect(channel.url).to eq("https://www.youtube.com/@LofiGirl/live")
    # The playlists a link resolves to carry a signature; a log never keeps one.
    expect(channel.redact("403 for https://rr1---sn-x.googlevideo.com/videoplayback/id/abc/sig/xyz.ts here"))
      .to eq("403 for YouTube's stream here")
  end

  it "takes a YouTube link only as a YouTube stream, and never a playlist" do
    playlist = described_class.new(household: household, library: library, name: "Mix", kind: "youtube",
      url: "https://www.youtube.com/playlist?list=PL1234567890abcdef")
    expect(playlist).not_to be_valid
    expect(playlist.errors.full_messages).to include(a_string_starting_with("A playlist isn't a live stream"))

    web = described_class.new(household: household, library: library, name: "Lofi", kind: "web", url: "https://www.youtube.com/watch?v=rFZHOHl-L8A")
    expect(web).not_to be_valid
    expect(web.errors[:url]).to include("is a YouTube link: choose YouTube as its kind")
  end

  it "keeps an MLB.tv game as its own link, with the feed it plays, and never a playlist's token in a log" do
    game = described_class.create!(household: household, library: library, name: "Mariners", kind: "mlb", feed: "home",
      url: "https://www.mlb.com/tv/g745652/vafbc56d6-7ad9-476d-98bb-04a247761609#game=745652")
    expect(game.url).to eq("https://www.mlb.com/tv/g745652")
    expect(game.source).to eq("mlb.com/tv/g745652")
    expect(game.feed_enum).to eq(LiveStream::Feed::Home)
    expect(game.redact("403 for https://mlb-cuts.test/x.m3u8?token=abc, from https://www.mlb.com/tv/g745652"))
      .to eq("403 for MLB.tv's stream, from https://www.mlb.com/tv/g745652")

    expect(described_class.new(household: household, library: library, name: "M", kind: "mlb", url: game.url)).not_to be_valid
    news = described_class.new(household: household, library: library, name: "M", kind: "mlb", feed: "away", url: "https://www.mlb.com/news/x")
    expect(news).not_to be_valid
    expect(news.errors.full_messages).to include("Paste a game's link from MLB.tv: mlb.com/tv/g…")

    web = described_class.new(household: household, library: library, name: "M", kind: "web", feed: "home", url: game.url)
    expect(web).not_to be_valid
    expect(web.errors[:url]).to include("is an MLB.tv link: choose MLB.tv as its kind")
    web.url = "https://example.com/n.m3u8"
    web.validate
    expect(web.feed).to be_nil
  end

  it "rates like any title" do
    stream = described_class.create!(household: household, library: library, name: "News", kind: "web",
      url: "https://example.com/n.m3u8", content_rating: "TV-14")
    expect(stream.rating_age).to eq(14)
  end
end

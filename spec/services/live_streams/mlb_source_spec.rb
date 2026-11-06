# typed: false
# frozen_string_literal: true

require "rails_helper"

# An MLB.tv game's playlists (PROPOSAL §7.8), with yt-dlp stubbed: signed in
# from a netrc file, the broadcast picked from what each format is, and what
# MLB.tv says turned into words.
RSpec.describe LiveStreams::MlbSource do
  let(:household) { Household.create!(name: "Family") }
  let(:library) { Library.create!(household: household, name: "Live", kind: "live") }
  let(:stream) do
    LiveStream.create!(household: household, library: library, name: "Mariners", kind: "mlb", feed: "away",
      url: "https://www.mlb.com/tv/g745652/vafbc56d6-7ad9-476d-98bb-04a247761609#game=745652")
  end
  let(:seen) { [] }
  let(:netrcs) { [] }

  let(:agent) { "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36" }

  def format(id, tbr, url: "https://mlb.test/#{id}.m3u8", vcodec: "avc1.640028", acodec: "mp4a.40.2", language: "en", headers: { "User-Agent" => agent })
    { "format_id" => id, "tbr" => tbr, "url" => url, "protocol" => "m3u8_native", "vcodec" => vcodec, "acodec" => acodec,
      "language" => language, "http_headers" => headers }
  end

  let(:formats) do
    [ format("Home-TV-en-6600", 6600), format("Away-TV-en-3500", 3500), format("Away-TV-en-6600", 6600),
      format("Away-TV-es-8000", 8000, language: "es"), format("Away-AUDIO-en-64", 64, vcodec: "none") ]
  end

  def answer(data: { "is_live" => true, "formats" => formats }, stderr: "", status: 0)
    allow(ToolRunner).to receive(:run) do |argv, **|
      seen << argv
      location = argv[argv.index("--netrc-location") + 1] if argv.include?("--netrc-location")
      netrcs << [ File.read(location), File.stat(location).mode & 0o777 ] if location && File.exist?(location)
      ToolRunner::Result.new(status: status, stdout: data.to_json, stderr: stderr)
    end
  end

  around do |example|
    cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = cache
  end

  before { MlbSetting.create!(household: household, username: "fan@example.com", password: %(pa ss#"word)) }

  it "signs in from a netrc file only yt-dlp reads, by the game's own link, and plays the chosen feed's best TV broadcast in English" do
    answer

    expect(described_class.resolve(stream)).to have_attributes(video: "https://mlb.test/Away-TV-en-6600.m3u8", audio: nil, user_agent: agent)
    argv = seen.sole
    expect(argv.last(2)).to eq([ "--", "https://www.mlb.com/tv/g745652" ])
    expect(argv).to include("--netrc", "--ignore-no-formats-error")
    expect(argv.join(" ")).not_to include("pa ss")
    expect(netrcs.sole).to eq([ %(machine mlb login "fan@example.com" password "pa ss#\\"word"\n), 0o600 ])
    expect(File.exist?(argv[argv.index("--netrc-location") + 1])).to be(false)

    expect(described_class.resolve(stream)).to have_attributes(video: "https://mlb.test/Away-TV-en-6600.m3u8", user_agent: agent)
    expect(seen.size).to eq(1)
    described_class.forget(stream)
    described_class.resolve(stream)
    expect(seen.size).to eq(2)
  end

  context "with a team's stream" do
    let(:team) { Mlb::TeamStreams.for(household.id, 114, "Cleveland Guardians") }
    let(:schedule) { instance_double(Mlb::Schedule) }

    before { allow(Mlb::Schedule).to receive(:new).and_return(schedule) }

    def playing(away_id)
      { "gamePk" => 849_815, "status" => { "abstractGameState" => "Live" },
        "teams" => { "away" => { "team" => { "id" => away_id } }, "home" => { "team" => { "id" => 139 } } } }
    end

    it "plays the game the team is on now, from the team's own side" do
      allow(schedule).to receive(:watchable_game).with(114).and_return(playing(114))
      answer

      expect(described_class.resolve(team).video).to eq("https://mlb.test/Away-TV-en-6600.m3u8")
      expect(seen.sole.last(2)).to eq([ "--", "https://www.mlb.com/tv/g849815" ])

      described_class.forget(team)
      allow(schedule).to receive(:watchable_game).with(114).and_return(playing(139))
      expect(described_class.resolve(team).video).to eq("https://mlb.test/Home-TV-en-6600.m3u8")
    end

    it "says so when the team isn't playing" do
      allow(schedule).to receive(:watchable_game).and_return(nil)

      expect { described_class.resolve(team) }
        .to raise_error(LiveStreams::Prober::Failure, "The Cleveland Guardians aren't playing on MLB.tv right now")
    end
  end

  describe ".pick" do
    it "falls back to the other feed, then any, whatever case yt-dlp names them in" do
      only_home = [ format("HOME-tv-en-6600", 6600), format("home-TV-en-3500", 3500) ]
      expect(described_class.pick(only_home, LiveStream::Feed::Away).video).to eq("https://mlb.test/HOME-tv-en-6600.m3u8")
      national = [ format("National-TV-en-5000", 5000) ]
      expect(described_class.pick(national, LiveStream::Feed::Home).video).to eq("https://mlb.test/National-TV-en-5000.m3u8")
    end

    it "takes the broadcast's own sound when the picture comes without it, and never radio" do
      apart = [ format("Home-TV-en-6600", 6600, acodec: "none"), format("Home-TV-en-audio-en", 128, vcodec: "none"),
                format("Away-TV-en-audio-en", 192, vcodec: "none"), format("Home-AUDIO-en-64", 64, vcodec: "none") ]
      expect(described_class.pick(apart, LiveStream::Feed::Home))
        .to have_attributes(video: "https://mlb.test/Home-TV-en-6600.m3u8", audio: "https://mlb.test/Home-TV-en-audio-en.m3u8")
      expect(described_class.pick([ format("Home-AUDIO-en-64", 64) ], LiveStream::Feed::Home)).to be_nil
    end

    it "reads the playlists with the User-Agent yt-dlp fetched them under, however it's capitalized, and without one when yt-dlp gave none" do
      expect(described_class.pick([ format("Home-TV-en-6600", 6600, headers: { "user-agent" => "Fetcher/1.0" }) ], LiveStream::Feed::Home))
        .to have_attributes(user_agent: "Fetcher/1.0")
      expect(described_class.pick([ format("Home-TV-en-6600", 6600, headers: nil) ], LiveStream::Feed::Home)).to have_attributes(user_agent: nil)
      expect(described_class.pick([ format("Home-TV-en-6600", 6600, headers: { "Accept" => "*/*" }) ], LiveStream::Feed::Home))
        .to have_attributes(user_agent: nil)
    end
  end

  it "says why there's nothing to play" do
    answer(data: { "is_live" => false, "formats" => formats })
    expect { described_class.resolve(stream) }.to raise_error(LiveStreams::Prober::Failure, "Mariners isn't live on MLB.tv right now")

    answer(data: { "is_live" => true, "formats" => [] },
      stderr: "WARNING: [mlb:tv] 745652: API returned errors for Away-TV-en: Content blacked out (https://mlb.test/x?token=abc)\n")
    expect { described_class.resolve(stream) }
      .to raise_error(LiveStreams::Prober::Failure, "Mariners is blacked out on MLB.tv where this server is")

    answer(stderr: "ERROR: [mlb:tv] Invalid username or password\n", status: 1)
    expect { described_class.resolve(stream) }
      .to raise_error(LiveStreams::Prober::Failure, "MLB.tv didn't accept the account in Settings › Integrations")

    answer(stderr: "ERROR: [mlb:tv] 745652: Unable to download JSON from https://media-gateway.mlb.com/x?token=abc\n", status: 1)
    expect { described_class.resolve(stream) }.to raise_error(LiveStreams::Prober::Failure) { |error|
      expect(error.message).to start_with("MLB.tv didn't give a stream: ")
      expect(error.message).not_to include("token=abc")
    }

    MlbSetting.delete_all
    expect { described_class.resolve(stream) }
      .to raise_error(LiveStreams::Prober::Failure, "Sign in to MLB.tv in Settings › Integrations first")
  end
end

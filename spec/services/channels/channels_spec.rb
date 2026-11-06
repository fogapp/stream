# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Channels" do
  let(:household) { Household.create!(name: "Tube") }
  let(:root) { build_root }
  let(:library) { create_library(household: household, roots: root, kind: "channels", name: "YouTube") }

  def write(relative, content)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    settle_library_roots!(root)
    path
  end

  def probed(relative, probe: {})
    path = write(relative, "video")
    MediaFile.create!(household: household, library: library, path: path, size: 5, mtime: Time.zone.parse("2023-06-01"),
      state: "probed", probe: probe, duration_seconds: 600)
  end

  def match(file) = Catalog::FileMatcher.new(file).call

  describe Media::NameParser do
    it "reads the channel folder, yt-dlp's id and a leading upload date" do
      parsed = Media::NameParser.parse("Technology Connections/20240131 - The Dishwasher [Ql7w1yX7hbI].mkv", Library::Kind::Channels)
      expect(parsed).to have_attributes(kind: Media::NameParser::Kind::Video, title: "The Dishwasher", youtube_id: "Ql7w1yX7hbI",
        air_date: Date.new(2024, 1, 31), show_folder: "Technology Connections")
    end
  end

  describe Channels::Timestamps do
    it "turns a description's timestamp lines into chapters, and ignores a stray time" do
      text = "Thanks for watching!\n0:00 Intro\n1:30 - The problem\n12:05 The fix\nSee you at 3:00 tomorrow"
      expect(described_class.chapters(text, 900.0)).to eq([
        { "start" => 0.0, "title" => "Intro", "end" => 90.0 },
        { "start" => 90.0, "title" => "The problem", "end" => 725.0 },
        { "start" => 725.0, "title" => "The fix", "end" => 900.0 }
      ])
      expect(described_class.chapters("Back at 3:00, then 4:00", 900.0)).to eq([])
    end
  end

  describe Catalog::VideoMatcher do
    it "files a video under its channel from yt-dlp's info.json, channel details from the channel's own" do
      write("Technology Connections/Technology Connections [UCy0tKL1T7wFoYcxCe0xjN6Q].info.json", {
        "_type" => "playlist", "channel" => "Technology Connections", "channel_id" => "UCy0tKL1T7wFoYcxCe0xjN6Q",
        "uploader_id" => "@TechnologyConnections", "channel_url" => "https://www.youtube.com/channel/UCy0", "description" => "Obscure tech."
      }.to_json)
      write("Technology Connections/The Dishwasher [Ql7w1yX7hbI].info.json", {
        "id" => "Ql7w1yX7hbI", "title" => "The Dishwasher Pod", "description" => "0:00 Hi\n1:00 Soap\n2:00 Bye",
        "upload_date" => "20240131", "channel" => "Technology Connections", "channel_id" => "UCy0tKL1T7wFoYcxCe0xjN6Q",
        "webpage_url" => "https://www.youtube.com/watch?v=Ql7w1yX7hbI", "tags" => %w[dishwasher],
        "chapters" => [ { "start_time" => 0, "end_time" => 60, "title" => "Hi" } ]
      }.to_json)
      file = probed("Technology Connections/The Dishwasher [Ql7w1yX7hbI].mkv")

      match(file)

      video = Video.sole
      expect(video).to have_attributes(title: "The Dishwasher Pod", upload_date: Date.new(2024, 1, 31), youtube_id: "Ql7w1yX7hbI",
        source: "info_json", tags: %w[dishwasher], chapters: [ { "start" => 0.0, "end" => 60.0, "title" => "Hi" } ])
      expect(video.media_files).to eq([ file ])
      expect(video.channel).to have_attributes(title: "Technology Connections", youtube_id: "UCy0tKL1T7wFoYcxCe0xjN6Q",
        handle: "@TechnologyConnections", description: "Obscure tech.", folder: "Technology Connections")
    end

    it "falls back to an NFO, then embedded tags, then the file name and its date" do
      write("Home Chef/Knife Skills.nfo", "<episodedetails><title>Knife skills, properly</title><plot>Cut.</plot>" \
        "<aired>2022-03-04</aired><studio>Home Chef TV</studio></episodedetails>")
      match(probed("Home Chef/Knife Skills.mkv"))
      match(probed("Home Chef/Stock.mkv", probe: { "format" => { "tags" => { "TITLE" => "Stock from scratch", "DATE" => "20220405" } } }))
      match(probed("Home Chef/Bread.mkv"))

      expect(Video.order(:upload_date).map { |v| [ v.title, v.source, v.upload_date.to_s ] }).to eq([
        [ "Knife skills, properly", "nfo", "2022-03-04" ], [ "Stock from scratch", "tags", "2022-04-05" ], [ "Bread", "folder", "2023-06-01" ]
      ])
      expect(Channel.sole.title).to eq("Home Chef TV")
    end

    it "keeps one video when a second copy of it turns up" do
      match(probed("Tube/A Talk [abcdefghijk].mkv"))
      match(probed("Tube/A Talk [abcdefghijk].webm"))
      expect(Video.sole.media_files.count).to eq(2)
    end
  end
end

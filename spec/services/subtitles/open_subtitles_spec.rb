# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "OpenSubtitles" do
  let(:household) { Household.create!(name: "Subs") }
  let(:root) { build_root }
  let(:library) { create_library(household: household, roots: root) }
  let(:storage) { Dir.mktmpdir("stream-storage") }
  let(:api) { "https://api.opensubtitles.com/api/v1" }

  before { stub_const("ENV", ENV.to_h.merge("STREAM_STORAGE_DIR" => storage)) }
  after { FileUtils.rm_rf(storage) }

  def movie_file(sidecar: nil)
    path = File.join(root, "Heat (1995)", "Heat (1995).mkv")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "video")
    File.write(path.sub(".mkv", ".en.srt"), sidecar) if sidecar
    file = MediaFile.create!(household: household, library: library, path: path, size: 5, mtime: Time.current, state: "probed",
      fingerprint: "8e245d9679d31e12")
    Movie.create!(household: household, library: library, title: "Heat", year: 1995, tmdb_id: 949).editions.create!(media_file: file)
    file
  end

  def result(file_id, hash_match:, downloads:, language: "en")
    { "attributes" => { "language" => language, "moviehash_match" => hash_match, "download_count" => downloads,
                        "hearing_impaired" => false, "files" => [ { "file_id" => file_id } ] } }
  end

  it "fetches the missing language, preferring the exact file over a more popular match, and keeps it as a track" do
    OpenSubtitlesSetting.create!(household: household, api_key: "k", languages: %w[en])
    file = movie_file
    stub_request(:get, "#{api}/subtitles").with(query: hash_including("moviehash" => "8e245d9679d31e12", "tmdb_id" => "949", "languages" => "en"))
      .to_return(status: 200, body: { data: [ result(1, hash_match: false, downloads: 9000), result(2, hash_match: true, downloads: 10) ] }.to_json)
    stub_request(:post, "#{api}/download").with(body: { file_id: 2, sub_format: "srt" }.to_json)
      .to_return(status: 200, body: { link: "https://dl.opensubtitles.com/x/2.srt", remaining: 4, reset_time_utc: 1.day.from_now.iso8601 }.to_json)
    stub_request(:get, "https://dl.opensubtitles.com/x/2.srt").to_return(status: 200, body: "1\n00:00:01,000 --> 00:00:02,000\nHi\n")

    FetchSubtitlesJob.perform_now(file.id)

    track = Subtitles::Tracks.for(file).find { |candidate| candidate.title == "OpenSubtitles" }
    expect(track).to have_attributes(language: "en", format: Subtitles::Tracks::Format::Vtt)
    expect(OpenSubtitlesSetting.sole.remaining_downloads).to eq(4)
    expect(file.analysis_runs.find_by(step: "subtitle_fetch").status).to eq("succeeded")
  end

  it "asks nothing when the language is already there, or the day's downloads are used up" do
    setting = OpenSubtitlesSetting.create!(household: household, api_key: "k", languages: %w[en])
    FetchSubtitlesJob.perform_now(movie_file(sidecar: "1\n00:00:01,000 --> 00:00:02,000\nHi\n").id)

    setting.update!(languages: %w[fr], remaining_downloads: 0, resets_at: 1.hour.from_now)
    FetchSubtitlesJob.perform_now(MediaFile.sole.id)
    expect(WebMock).not_to have_requested(:any, /opensubtitles/)
  end

  it "refuses a download link that points anywhere but OpenSubtitles" do
    setting = OpenSubtitlesSetting.create!(household: household, api_key: "k", languages: %w[en])
    stub_request(:post, "#{api}/download").to_return(status: 200, body: { link: "http://192.168.1.1/evil" }.to_json)
    candidate = Subtitles::OpenSubtitles::Candidate.new(file_id: 1, language: "en", hash_match: true, downloads: 1, hearing_impaired: false, release: nil)
    expect { Subtitles::OpenSubtitles.new(setting).download(candidate) }.to raise_error(Subtitles::OpenSubtitles::Error)
  end
end

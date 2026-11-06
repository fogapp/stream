# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Home videos" do
  let(:household) { Household.create!(name: "Family") }
  let(:root) { build_root }
  let(:library) { create_library(household: household, roots: root, kind: "home_videos", name: "Home videos") }

  def probed(relative, tags: nil, mtime: Time.zone.parse("2024-06-01 12:00"))
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "video")
    settle_library_roots!(root)
    MediaFile.create!(household: household, library: library, path: path, size: 5, mtime: mtime, state: "probed",
      probe: tags ? { "format" => { "tags" => tags } } : {}, duration_seconds: 30)
  end

  def match(file) = Catalog::FileMatcher.new(file).call

  it "places a clip by the camera's own clock, then a camera-style name, then the file's date" do
    match(probed("2023/beach.mov", tags: { "com.apple.quicktime.creationdate" => "2023-07-14T16:20:05+0100" }))
    match(probed("phone/PXL_20220305_101112345.mp4"))
    match(probed("old/tape.avi", tags: { "creation_time" => "1970-01-01T00:00:00Z" }))

    clips = Clip.order(:captured_at).map { |clip| [ clip.title, clip.captured_source, clip.captured_at.to_date.to_s ] }
    expect(clips).to eq([ [ "PXL 20220305 101112345", "filename", "2022-03-05" ], [ "beach", "metadata", "2023-07-14" ],
                          [ "tape", "file_date", "2024-06-01" ] ])
    expect(Clip.find_by(title: "beach").media_files.count).to eq(1)
    # The name's time is the camera's wall clock, kept as-is.
    expect(Clip.find_by(captured_source: "filename")).to have_attributes(captured_floating: true,
      captured_at: Time.utc(2022, 3, 5, 10, 11, 12))
    expect(Clip.find_by(title: "beach").captured_floating).to be(false)
  end

  describe "the API", type: :request do
    include ActiveSupport::Testing::TimeHelpers

    let(:user) { create_user(household: household) }

    it "lists a library's clips newest first with a year summary, and one clip with the rest of its day" do
      morning = probed("a.mp4", tags: { "creation_time" => "2023-07-14T09:00:00Z" })
      match(morning)
      match(probed("b.mp4", tags: { "creation_time" => "2023-07-14T15:00:00Z" }))
      match(probed("c.mp4", tags: { "creation_time" => "2021-01-01T10:00:00Z" }))

      get "/api/v1/clips", params: { library_id: library.id }, headers: auth_headers(user)
      expect(json["years"]).to eq([ { "year" => 2023, "count" => 2 }, { "year" => 2021, "count" => 1 } ])
      expect(json["clips"].map { |clip| clip["title"] }).to eq(%w[b a c])

      clip = Clip.find_by(title: "a")
      get "/api/v1/clips/#{clip.id}", headers: auth_headers(user)
      expect(json["same_day"].map { |other| other["title"] }).to eq(%w[b])
    end

    it "puts clips from this date in earlier years on Home as On this day" do
      travel_to Time.zone.parse("2026-07-14 12:00") do
        match(probed("old.mp4", tags: { "creation_time" => "2023-07-14T09:00:00Z" }))
        match(probed("other.mp4", tags: { "creation_time" => "2023-07-15T09:00:00Z" }))
        get "/api/v1/home", headers: auth_headers(user)
        row = json["hubs"].find { |hub| hub["key"] == "on_this_day" }
        expect(row["items"].map { |clip| clip["title"] }).to eq(%w[old])
      end
    end
  end
end

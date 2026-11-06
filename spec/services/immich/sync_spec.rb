# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Immich::Sync do
  let(:household) { Household.create!(name: "Family") }
  let(:root) { build_root }
  let(:library) { create_library(household: household, roots: root, kind: "home_videos", name: "Home videos") }
  let(:setting) do
    ImmichSetting.create!(household: household, url: "http://immich.lan:2283", api_key: "k",
      immich_path_prefix: "/usr/src/app/upload", local_path_prefix: root)
  end
  let(:api) { "http://immich.lan:2283/api" }

  def clip_file(relative)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "video")
    settle_library_roots!(root)
    file = MediaFile.create!(household: household, library: library, path: path, size: 5, mtime: Time.zone.parse("2024-06-01"), state: "probed")
    Catalog::FileMatcher.new(file).call
    Clip.joins(:editions).find_by(editions: { media_file_id: file.id })
  end

  def json(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }

  def stub_immich(videos:, albums: [], album_assets: {})
    stub_request(:get, "#{api}/people?withHidden=false").to_return(json(people: [ { id: "p1", name: "Ada" }, { id: "p2", name: "" } ]))
    stub_request(:post, "#{api}/search/metadata").to_return(json(assets: { items: videos, nextPage: nil }))
    stub_request(:get, "#{api}/albums").to_return(json(albums))
    album_assets.each { |id, assets| stub_request(:get, "#{api}/albums/#{id}").to_return(json(assets: assets.map { |a| { id: a } })) }
  end

  it "touches a clip that's already right with no queries of its own" do
    (1..3).each { |number| clip_file("library/a#{number}.mp4") }
    videos = ->(count) { (1..count).map { |n| { id: "a#{n}", originalPath: "/usr/src/app/upload/library/a#{n}.mp4", people: [ { id: "p1" } ] } } }
    stub_immich(videos: videos.call(3))
    described_class.new(setting).call

    one = count_queries { described_class.new(setting).call }.size
    stub_immich(videos: videos.call(1))
    fewer = count_queries { described_class.new(setting).call }.size

    expect(one).to eq(fewer)
    expect(count_queries(matching: /DELETE FROM "clip_people"/) { described_class.new(setting).call }).to be_empty
  end

  it "brings when, where, who and which albums across, matched by the file's path" do
    beach = clip_file("library/admin/2023/07/beach.mp4")
    clip_file("library/admin/2023/07/other.mp4")
    stub_immich(
      videos: [
        { id: "a1", originalPath: "/usr/src/app/upload/library/admin/2023/07/beach.mp4", localDateTime: "2023-07-14T16:20:05.000Z",
          isFavorite: true, exifInfo: { city: "Brighton", country: "United Kingdom", description: "First swim" },
          people: [ { id: "p1", name: "Ada" } ] },
        { id: "a2", originalPath: "/usr/src/app/upload/library/admin/elsewhere.mp4", localDateTime: "2023-01-01T00:00:00.000Z" },
        { id: "a3", originalPath: "/usr/src/app/upload/x.mov", visibility: "hidden" }
      ],
      albums: [ { id: "al1", albumName: "Summer 2023" }, { id: "al2", albumName: "Photos only" } ],
      album_assets: { "al1" => %w[a1 photo9], "al2" => %w[photo1] }
    )

    counts = described_class.new(setting).call

    expect(counts).to include("videos_in_immich" => 2, "clips_updated" => 1, "not_found_in_stream" => 1, "albums" => 1, "people" => 1)
    expect(beach.reload).to have_attributes(immich_id: "a1", city: "Brighton", description: "First swim", favorite: true,
      captured_source: "immich", captured_floating: true, captured_at: Time.utc(2023, 7, 14, 16, 20, 5))
    expect(beach.home_people.map(&:name)).to eq([ "Ada" ])
    expect(Album.sole).to have_attributes(title: "Summer 2023")
    expect(Album.sole.clips).to eq([ beach ])
    expect(setting.reload.last_synced_at).to be_present
  end

  it "reads every page of videos, and a second sync changes nothing" do
    beach = clip_file("library/admin/2023/07/beach.mp4")
    party = clip_file("library/admin/2023/08/party.mp4")
    video = ->(id, path, person) {
      { id: id, originalPath: "/usr/src/app/upload/#{path}", localDateTime: "2023-07-14T16:20:05.000Z", people: [ { id: person, name: "Ada" } ] }
    }
    stub_immich(videos: [], albums: [ { id: "al1", albumName: "Summer" } ], album_assets: { "al1" => %w[a1 a2] })
    stub_request(:post, "#{api}/search/metadata").with(body: hash_including("page" => 1))
      .to_return(json(assets: { items: [ video.call("a1", "library/admin/2023/07/beach.mp4", "p1") ], nextPage: "2" }))
    stub_request(:post, "#{api}/search/metadata").with(body: hash_including("page" => "2"))
      .to_return(json(assets: { items: [ video.call("a2", "library/admin/2023/08/party.mp4", "p1") ], nextPage: nil }))

    counts = described_class.new(setting).call

    expect(counts).to include("videos_in_immich" => 2, "clips_updated" => 2)
    expect([ beach.reload.immich_id, party.reload.immich_id ]).to eq(%w[a1 a2])
    snapshot = -> { [ HomePerson.count, ClipPerson.count, Album.count, AlbumClip.count, Clip.order(:id).map(&:attributes) ] }
    before = snapshot.call
    expect(before.first(4)).to eq([ 1, 2, 1, 2 ])

    described_class.new(setting).call

    expect(snapshot.call).to eq(before)
  end

  it "drops an album Immich no longer has, and says why a sync failed" do
    Album.create!(household: household, title: "Gone", immich_id: "old")
    stub_immich(videos: [])
    described_class.new(setting).call
    expect(Album.count).to eq(0)

    stub_request(:get, "#{api}/people?withHidden=false").to_return(status: 401, body: "{}")
    described_class.new(setting).call
    expect(setting.reload.last_sync_error).to be_present
  end
end

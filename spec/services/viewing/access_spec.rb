# typed: false
# frozen_string_literal: true

require "rails_helper"

# The one place that decides what a profile may see (CLAUDE.md), taken one
# content type at a time: its libraries, its rating ceiling (unrated only if
# allowed), curated mode (only what's tagged), and a tag letting one title
# past the ceiling.
RSpec.describe Viewing::Access do
  let(:household) { Household.create!(name: "Family") }
  let(:films) { create_library(household: household, roots: build_root, name: "Films") }
  let(:family_films) { create_library(household: household, roots: build_root, name: "Family films") }
  let(:tv) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }
  let(:tube) { create_library(household: household, roots: build_root, kind: "channels", name: "YouTube") }
  let(:home) { create_library(household: household, roots: build_root, kind: "home_videos", name: "Home") }

  let!(:paddington) { Movie.create!(household: household, library: family_films, title: "Paddington", content_rating: "PG") }
  let!(:alien) { Movie.create!(household: household, library: films, title: "Alien", content_rating: "R") }
  let!(:unrated) { Movie.create!(household: household, library: films, title: "Festival cut") }
  let!(:bluey) { show("Bluey", "TV-Y") }
  let!(:severance) { show("Severance", "TV-MA") }
  let!(:tc) { Channel.create!(household: household, library: tube, folder: "TC", title: "Technology Connections") }
  let!(:video) { Video.create!(household: household, library: tube, channel: tc, title: "Dishwashers", upload_date: Date.current, source: "folder") }
  let!(:beach) { clip("Beach") }
  let!(:party) { clip("Party") }
  let!(:summer) { Album.create!(household: household, title: "Summer", immich_id: "a1").tap { |album| AlbumClip.create!(album: album, clip: beach) } }

  def show(title, rating)
    Show.create!(household: household, library: tv, folder: title, title: title, content_rating: rating).tap do |series|
      season = series.seasons.create!(season_number: 1)
      series.episodes.create!(season: season, season_number: 1, episode_number: 1, title: "#{title} 1")
    end
  end

  def clip(title)
    Clip.create!(household: household, library: home, title: title, sort_title: title, captured_at: Time.current, captured_source: "immich")
  end

  def profile(**attributes) = Profile.create!(household: household, name: "P#{SecureRandom.hex(2)}", **attributes)

  def as(viewer)
    Current.profile = viewer
    yield
  ensure
    Current.profile = nil
  end

  def titles(viewer)
    as(viewer) do
      {
        movies: described_class.movies(Movie.all).pluck(:title).sort,
        shows: described_class.shows(Show.all).pluck(:title).sort,
        episodes: described_class.episodes(Episode.all).pluck(:title).sort,
        channels: described_class.channels(Channel.all).pluck(:title),
        videos: described_class.videos(Video.all).pluck(:title),
        clips: described_class.clips(Clip.all).pluck(:title).sort
      }
    end
  end

  it "changes nothing without a profile, or for one with no limits" do
    everything = { movies: [ "Alien", "Festival cut", "Paddington" ], shows: %w[Bluey Severance], episodes: [ "Bluey 1", "Severance 1" ],
                   channels: [ "Technology Connections" ], videos: [ "Dishwashers" ], clips: %w[Beach Party] }

    expect(titles(nil)).to eq(everything)
    expect(titles(profile)).to eq(everything)
    expect(profile).not_to be_restricted
  end

  it "holds a ceiling across films, shows and their episodes, and hides the unrated and unratable" do
    expect(titles(profile(max_rating_age: 10))).to eq(movies: [ "Paddington" ], shows: [ "Bluey" ], episodes: [ "Bluey 1" ],
      channels: [], videos: [], clips: [])
  end

  it "lets the unrated through a ceiling only when allowed" do
    expect(titles(profile(max_rating_age: 10, allow_unrated: true))).to eq(movies: [ "Festival cut", "Paddington" ], shows: [ "Bluey" ],
      episodes: [ "Bluey 1" ], channels: [ "Technology Connections" ], videos: [ "Dishwashers" ], clips: %w[Beach Party])
  end

  it "lets a tagged title past the ceiling, and its episodes or videos with it" do
    viewer = profile(max_rating_age: 7)
    [ alien, severance, tc, summer ].each { |title| ProfileTag.create!(profile: viewer, taggable: title) }

    # Paddington is PG (8): over this ceiling, and not tagged.
    expect(titles(viewer)).to eq(movies: [ "Alien" ], shows: %w[Bluey Severance], episodes: [ "Bluey 1", "Severance 1" ],
      channels: [ "Technology Connections" ], videos: [ "Dishwashers" ], clips: [ "Beach" ])
  end

  it "shows a curated profile only what's tagged for it, whatever the rating" do
    viewer = profile(curated: true)
    [ paddington, bluey, summer ].each { |title| ProfileTag.create!(profile: viewer, taggable: title) }

    expect(titles(viewer)).to eq(movies: [ "Paddington" ], shows: [ "Bluey" ], episodes: [ "Bluey 1" ], channels: [], videos: [],
      clips: [ "Beach" ])
  end

  it "keeps a profile to its libraries" do
    viewer = profile(library_ids: [ family_films.id, home.id ])

    expect(titles(viewer)).to eq(movies: [ "Paddington" ], shows: [], episodes: [], channels: [], videos: [], clips: %w[Beach Party])
  end

  it "only counts a tag inside the profile's libraries" do
    viewer = profile(library_ids: [ family_films.id ], max_rating_age: 16)
    ProfileTag.create!(profile: viewer, taggable: alien)

    expect(titles(viewer)[:movies]).to eq([ "Paddington" ])
  end

  it "leaves out what a profile hid from itself, whatever its limits or tags say" do
    open_viewer = profile
    [ alien, severance, tc ].each { |title| ProfileExclusion.create!(profile: open_viewer, excludable: title) }
    expect(titles(open_viewer)).to eq(movies: [ "Festival cut", "Paddington" ], shows: [ "Bluey" ], episodes: [ "Bluey 1" ],
      channels: [], videos: [], clips: %w[Beach Party])

    curated = profile(curated: true)
    ProfileTag.create!(profile: curated, taggable: paddington)
    ProfileExclusion.create!(profile: curated, excludable: paddington)
    expect(titles(curated)[:movies]).to eq([])

    tagged_past = profile(max_rating_age: 7, allow_unrated: true)
    ProfileTag.create!(profile: tagged_past, taggable: alien)
    [ alien, unrated ].each { |title| ProfileExclusion.create!(profile: tagged_past, excludable: title) }
    expect(titles(tagged_past)[:movies]).to eq([])
  end

  describe ".allows?" do
    it "answers for one title of each kind the way the lists do" do
      viewer = profile(max_rating_age: 10)
      extra = ->(owner, title) {
        file = MediaFile.create!(household: household, library: films, path: "/f/#{title}.mkv", size: 1, mtime: Time.current, state: "probed")
        Extra.create!(household: household, media_file: file, owner: owner, kind: "trailer", title: title)
      }
      trailer = extra.call(alien, "Alien trailer")
      bluey_extra = extra.call(bluey.seasons.first, "Making Bluey")
      orphan = extra.call(nil, "Loose trailer")

      as(viewer) do
        expect(described_class.allows?(paddington)).to be(true)
        expect(described_class.allows?(alien)).to be(false)
        expect(described_class.allows?(bluey.episodes.first)).to be(true)
        expect(described_class.allows?(severance)).to be(false)
        expect(described_class.allows?(severance.episodes.first)).to be(false)
        expect(described_class.allows?(video)).to be(false)
        expect(described_class.allows?(tc)).to be(false)
        expect(described_class.allows?(beach)).to be(false)
        expect(described_class.allows?(trailer)).to be(false) # follows the film it belongs to
        expect(described_class.allows?(bluey_extra)).to be(true) # a season's extra follows its show
        expect(described_class.allows?(orphan)).to be(true)
      end
    end
  end

  describe ".stations" do
    let(:file) do
      MediaFile.create!(household: household, library: films, path: "/f/#{SecureRandom.hex(3)}.mkv", size: 1, mtime: Time.current,
        state: "probed", duration_seconds: 60)
    end

    def spare_file
      MediaFile.create!(household: household, library: films, path: "/f/#{SecureRandom.hex(3)}.mkv", size: 1, mtime: Time.current, state: "probed", duration_seconds: 60)
    end

    def airing(station, playable, starts:, ends:)
      Airing.create!(household: household, station: station, playable: playable, media_file: file, series_key: "x",
        starts_at: starts, ends_at: ends, reason: "Test")
    end

    it "shows a channel only while everything still to air on it is allowed" do
      kids = Station.create!(household: household, number: "2", name: "Kids")
      late = Station.create!(household: household, number: "3", name: "Late")
      reformed = Station.create!(household: household, number: "4", name: "Reformed")
      airing(kids, paddington, starts: 1.hour.ago, ends: 1.hour.from_now)
      airing(kids, bluey.episodes.first, starts: 1.hour.from_now, ends: 2.hours.from_now)
      airing(late, paddington, starts: 1.hour.ago, ends: 1.hour.from_now)
      airing(late, severance.episodes.first, starts: 3.hours.from_now, ends: 4.hours.from_now)
      airing(reformed, alien, starts: 3.hours.ago, ends: 1.hour.ago) # over: no longer counts
      airing(reformed, paddington, starts: 1.hour.ago, ends: 1.hour.from_now)

      as(profile(max_rating_age: 10)) do
        expect(described_class.stations(Station.all).pluck(:name)).to contain_exactly("Kids", "Reformed")
        expect(described_class.allows?(late)).to be(false)
      end
    end

    it "takes a channel off a profile that hid something still to air on it" do
      kids = Station.create!(household: household, number: "2", name: "Kids")
      airing(kids, bluey.episodes.first, starts: 1.hour.from_now, ends: 2.hours.from_now)
      viewer = profile
      ProfileExclusion.create!(profile: viewer, excludable: bluey)

      as(viewer) { expect(described_class.stations(Station.all)).to be_empty }
    end

    it "counts an extra still to air by the title it belongs to" do
      filler = ->(owner) { Extra.create!(household: household, owner: owner, kind: "trailer", title: "Trailer #{SecureRandom.hex(2)}", media_file: spare_file) }
      kids = Station.create!(household: household, number: "2", name: "Kids")
      trailers = Station.create!(household: household, number: "3", name: "Trailers")
      airing(kids, filler.call(paddington), starts: 1.hour.ago, ends: 1.hour.from_now)
      airing(trailers, filler.call(alien), starts: 1.hour.from_now, ends: 2.hours.from_now)

      as(profile(max_rating_age: 10)) { expect(described_class.stations(Station.all).pluck(:name)).to eq([ "Kids" ]) }
    end

    it "treats a TV extra by its show, and one that belongs to nothing as anyone's" do
      season = severance.seasons.first
      scene = Extra.create!(household: household, owner: season, kind: "scene", title: "Scene", media_file: spare_file)
      own = Extra.create!(household: household, owner: bluey, kind: "scene", title: "Own", media_file: spare_file)
      loose = Extra.create!(household: household, kind: "short", title: "Loose", media_file: spare_file)

      as(profile(max_rating_age: 10)) do
        expect(described_class.extras(Extra.all)).to contain_exactly(own, loose)
        expect(described_class.permitted([ scene, own, loose ])).to eq([ own, loose ])
        expect(described_class.allows?(scene)).to be(false)
      end
    end

    it "treats a YouTube channel's videos as unrated: shown with unrated allowed or the channel tagged" do
      tube_tv = Station.create!(household: household, number: "5", name: "Tube")
      airing(tube_tv, video, starts: 1.hour.ago, ends: 1.hour.from_now)
      strict = profile(max_rating_age: 10, allow_unrated: false)

      as(strict) { expect(described_class.stations(Station.all).pluck(:name)).to be_empty }
      as(profile(max_rating_age: 10, allow_unrated: true)) { expect(described_class.stations(Station.all).pluck(:name)).to eq([ "Tube" ]) }
      ProfileTag.create!(profile: strict, taggable: tc)
      as(strict) { expect(described_class.stations(Station.all).pluck(:name)).to eq([ "Tube" ]) }
    end
  end
end

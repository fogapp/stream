# typed: false
# frozen_string_literal: true

require "rails_helper"

# What a TMDB refresh writes (PROPOSAL §5.2), and that it writes it in a few
# statements however long the cast list or the season is.
RSpec.describe Catalog::Metadata do
  let(:household) { Household.create!(name: "Metadata") }
  let(:films) { create_library(household: household, roots: build_root) }
  let(:tv) { create_library(household: household, roots: build_root, kind: "shows") }

  before { allow(Artworks).to receive(:enqueue_for) }

  def cast(count, from: 1)
    (from...(from + count)).map { |n| { "id" => 10_000 + n, "name" => "Actor #{n}", "character" => "Role #{n}", "profile_path" => "/a#{n}.jpg" } }
  end

  def credits_of(record)
    record.credits.reload.includes(:person).order(:order, :role)
      .map { |credit| [ credit.person.tmdb_id, credit.person.name, credit.role, credit.character, credit.job, credit.order ] }
  end

  it "replaces a film's credits: cast in order, directors and writers, one person each, and someone in two roles twice" do
    movie = Movie.create!(household: household, library: films, title: "Heat")
    Person.create!(tmdb_id: 9002, name: "M. Mann", profile_path: "/kept.jpg")
    details = tmdb_movie(id: 949, title: "Heat", date: "1995-12-15").merge("credits" => {
      "cast" => [ { "id" => 9001, "name" => "Al Pacino", "character" => "Hanna", "profile_path" => "/al.jpg" },
        { "id" => 9001, "name" => "Al Pacino", "character" => "Hanna again", "profile_path" => "/al.jpg" },
        { "id" => nil, "name" => "Nobody" }, { "id" => 9004, "name" => "" },
        { "id" => 9005, "name" => "Val Kilmer", "character" => "", "profile_path" => nil } ],
      "crew" => [ { "id" => 9002, "name" => "Michael Mann", "job" => "Director", "profile_path" => "" },
        { "id" => 9002, "name" => "Michael Mann", "job" => "Screenplay", "profile_path" => "/mann.jpg" },
        { "id" => 9006, "name" => "Grip", "job" => "Grip" } ]
    })

    described_class.apply_movie(movie, details)

    expect(credits_of(movie)).to eq([
      [ 9001, "Al Pacino", "cast", "Hanna", nil, 0 ],
      [ 9005, "Val Kilmer", "cast", nil, nil, 4 ],
      [ 9002, "Michael Mann", "director", nil, "Director", 5 ],
      [ 9002, "Michael Mann", "writer", nil, "Screenplay", 6 ]
    ])
    # A blank picture never overwrites a known one; a later one replaces it.
    expect(Person.find_by(tmdb_id: 9002)).to have_attributes(name: "Michael Mann", profile_path: "/mann.jpg")
    expect(Person.find_by(tmdb_id: 9005).profile_path).to be_nil
    expect(Person.where(tmdb_id: [ 9004, 9006 ])).to be_empty

    # Again, with a blank picture this time: the one known is kept.
    details["credits"]["crew"] = [ { "id" => 9002, "name" => "Michael Mann", "job" => "Director", "profile_path" => nil } ]
    described_class.apply_movie(movie.reload, details)
    expect(Person.find_by(tmdb_id: 9002).profile_path).to eq("/mann.jpg")
    expect(credits_of(movie).map(&:first)).to eq([ 9001, 9005, 9002 ])
  end

  it "writes a film's credits in the same number of statements however long the cast is" do
    movie = Movie.create!(household: household, library: films, title: "Heat")
    apply = ->(members) { described_class.apply_movie(movie.reload, tmdb_movie(id: 949, title: "Heat", date: "1995-12-15").merge("credits" => { "cast" => members, "crew" => [] })) }
    credits = /"(people|credits)"/
    apply.call(cast(2))
    small = count_queries(matching: credits) { apply.call(cast(2, from: 50)) }
    large = count_queries(matching: credits) { apply.call(cast(18, from: 100)) }

    expect(large.size).to eq(small.size), large.join("\n")
    expect(movie.credits.count).to eq(18)
    expect(Person.where(tmdb_id: 10_100..10_117).count).to eq(18)
  end

  it "keeps a show's seasons by number, and refreshes them in the same statements however many there are" do
    show = Show.create!(household: household, library: tv, folder: "Severance", title: "Severance")
    described_class.apply_show(show, tmdb_show(id: 95_396, name: "Severance", date: "2022-02-18", seasons: [ 1, 2 ]))
    first = show.seasons.find_by(season_number: 1)
    expect(show.seasons.order(:season_number).pluck(:season_number, :title, :tmdb_id)).to eq([ [ 1, "Season 1", 953_961 ], [ 2, "Season 2", 953_962 ] ])

    seasons = /"seasons"/
    small = count_queries(matching: seasons) { described_class.apply_show(show.reload, tmdb_show(id: 95_396, name: "Severance", date: "2022-02-18", seasons: [ 1, 2 ])) }
    described_class.apply_show(show.reload, tmdb_show(id: 95_396, name: "Severance", date: "2022-02-18", seasons: (0..8).to_a))
    large = count_queries(matching: seasons) { described_class.apply_show(show.reload, tmdb_show(id: 95_396, name: "Severance", date: "2022-02-18", seasons: (0..8).to_a)) }

    expect(large.size).to eq(small.size), large.join("\n")
    expect(show.seasons.find_by(season_number: 1).id).to eq(first.id)
    expect(show.seasons.count).to eq(9)
    expect(show.credits.sole).to have_attributes(role: "creator", job: "Creator")
  end

  it "matches a season's episodes by number, keeps their files and locked fields, and refreshes them in the same statements however many" do
    show = Show.create!(household: household, library: tv, folder: "Severance", title: "Severance")
    season = described_class.apply_season(show, tmdb_season(1, [ [ 1, "Good News About Hell" ], [ 2, "Half Loop" ] ]))
    pilot = show.episodes.find_by(episode_number: 1)
    pilot.update!(title: "My title", locked_fields: [ "title" ])

    described_class.apply_season(show.reload, tmdb_season(1, [ [ 1, "Good News About Hell" ], [ 2, "Half Loop (new)" ], [ 3, "In Perpetuity" ] ]))
    expect(show.episodes.order(:episode_number).pluck(:episode_number, :title, :season_id, :tmdb_id, :air_date))
      .to eq([ [ 1, "My title", season.id, 101, Date.new(2022, 2, 1) ], [ 2, "Half Loop (new)", season.id, 102, Date.new(2022, 2, 2) ],
        [ 3, "In Perpetuity", season.id, 103, Date.new(2022, 2, 3) ] ])
    expect(show.episodes.find_by(episode_number: 1).id).to eq(pilot.id)
    expect(season.reload.episode_count).to eq(3)

    episodes = /"episodes"/
    few = (1..3).map { |n| [ n, "Episode #{n}" ] }
    many = (1..12).map { |n| [ n, "Episode #{n}" ] }
    described_class.apply_season(show.reload, tmdb_season(1, few))
    small = count_queries(matching: episodes) { described_class.apply_season(show.reload, tmdb_season(1, few)) }
    described_class.apply_season(show.reload, tmdb_season(1, many))
    large = count_queries(matching: episodes) { described_class.apply_season(show.reload, tmdb_season(1, many)) }
    expect(large.size).to eq(small.size), large.join("\n")
    expect(show.episodes.find_by(episode_number: 1).title).to eq("My title")
  end
end

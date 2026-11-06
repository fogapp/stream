# typed: false
# frozen_string_literal: true

# TMDB stubs (webmock — no real network, ever). Bodies are the smallest
# shapes the code reads, written out by hand from TMDB's v3 responses.
module TmdbHelpers
  TMDB = "https://api.themoviedb.org/3"

  def configure_tmdb(household, key: "v3-test-key")
    TmdbSetting.for_household!(household).update!(api_key: key)
  end

  def stub_tmdb(path, body, query: {})
    stub_request(:get, %r{\A#{Regexp.escape(TMDB + path)}\?})
      .with(query: hash_including(query.transform_keys(&:to_s).transform_values(&:to_s)))
      .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def tmdb_movie(id:, title:, date:, **extra)
    {
      "id" => id, "title" => title, "original_title" => title, "release_date" => date, "overview" => "About #{title}.",
      "tagline" => "A tagline.", "runtime" => 120, "genres" => [ { "id" => 1, "name" => "Drama" } ],
      "vote_average" => 7.9, "imdb_id" => "tt#{id.to_s.rjust(7, '0')}", "poster_path" => "/p#{id}.jpg",
      "backdrop_path" => "/b#{id}.jpg",
      "release_dates" => { "results" => [ { "iso_3166_1" => "US", "release_dates" => [ { "certification" => "R" } ] } ] },
      "images" => { "logos" => [ { "file_path" => "/l#{id}.png", "iso_639_1" => "en", "vote_average" => 5 } ] },
      "credits" => {
        "cast" => [ { "id" => 9001, "name" => "Al Pacino", "character" => "Hanna", "profile_path" => "/al.jpg" } ],
        "crew" => [ { "id" => 9002, "name" => "Michael Mann", "job" => "Director" } ]
      }
    }.merge(extra.transform_keys(&:to_s))
  end

  def tmdb_show(id:, name:, date:, seasons: [ 1 ])
    {
      "id" => id, "name" => name, "original_name" => name, "first_air_date" => date, "overview" => "About #{name}.",
      "status" => "Returning Series", "networks" => [ { "name" => "Apple TV+" } ], "genres" => [ { "name" => "Drama" } ],
      "external_ids" => { "imdb_id" => "tt11280740", "tvdb_id" => 371_980 },
      "content_ratings" => { "results" => [ { "iso_3166_1" => "US", "rating" => "TV-MA" } ] },
      "seasons" => seasons.map { |n| { "season_number" => n, "name" => "Season #{n}", "episode_count" => 2, "id" => (id * 10) + n } },
      "credits" => { "cast" => [], "crew" => [] }, "created_by" => [ { "id" => 9003, "name" => "Dan Erickson" } ]
    }
  end

  def tmdb_season(number, episodes)
    {
      "id" => 500 + number, "season_number" => number, "name" => "Season #{number}",
      "episodes" => episodes.map { |n, title| { "id" => (number * 100) + n, "episode_number" => n, "name" => title, "air_date" => "2022-02-#{n.to_s.rjust(2, '0')}" } }
    }
  end
end

RSpec.configure do |config|
  config.include TmdbHelpers
end

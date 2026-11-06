# typed: false
# frozen_string_literal: true

require "rails_helper"

# Asking Hook from the palette (PROPOSAL §7.9), with Hook stubbed at its
# address: search beyond Stream, want a film, add a show and want its
# seasons, follow it — each call naming the person who asked.
RSpec.describe "Asking Hook", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin", email: "sam@example.com") }
  let(:member) { create_user(household: household, email: "kim@example.com") }
  let(:hook) { "http://hook" }
  let(:show_id) { "0b7c6c1e-3f7e-4f6a-9a51-2d1f0c4e8a10" }
  let(:asked_by) { { "Authorization" => "Bearer hook_requests", "Hook-On-Behalf-Of" => "kim@example.com" } }

  before { stub_const("ENV", ENV.to_h.merge("HOOK_URL" => hook, "HOOK_API_TOKEN" => "hook_requests")) }

  def json_body(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }

  def episode(season, number, aired: true, wants: [])
    { "id" => SecureRandom.uuid, "season_number" => season, "episode_number" => number, "aired" => aired,
      "air_date" => aired ? "2022-02-18" : "2026-11-06", "wants" => wants }
  end

  def hook_show(following: nil)
    { "id" => show_id, "title" => "Severance", "year" => 2022, "tmdb_id" => 95_396, "network" => "Apple TV+",
      "poster_url" => "https://image.tmdb.org/t/p/w500/s.jpg", "following" => following,
      "seasons" => [
        { "season_number" => 0, "episodes" => [ episode(0, 1) ] },
        { "season_number" => 1, "episodes" => [ episode(1, 1), episode(1, 2) ] },
        { "season_number" => 2, "episodes" => [ episode(2, 1, wants: [ { "status" => "wanted" } ]), episode(2, 2, aired: false) ] }
      ] }
  end

  def held_show(seasons)
    library = create_library(household: household, roots: build_root, kind: "shows", name: "TV")
    Show.create!(household: household, library: library, folder: "Severance", title: "Severance", tmdb_id: 95_396).tap do |series|
      seasons.each do |number, episodes|
        season = series.seasons.create!(season_number: number)
        episodes.each do |episode_number|
          file = MediaFile.create!(household: household, library: library, path: "/tv/s#{number}e#{episode_number}.mkv", size: 1,
            mtime: Time.current, state: "probed")
          series.episodes.create!(season: season, season_number: number, episode_number: episode_number).editions.create!(media_file: file)
        end
      end
    end
  end

  it "offers Hook to the household's grown-ups once fog has connected it" do
    get "/api/v1/hook", headers: auth_headers(member)
    expect(json).to eq("available" => true)

    kid = Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 10)
    get "/api/v1/hook", headers: auth_headers(member).merge(profile_header(kid))
    expect(json).to eq("available" => false)
    get "/api/v1/hook/search", params: { kind: "movie", q: "arrival" }, headers: auth_headers(member).merge(profile_header(kid))
    expect(response).to have_http_status(:forbidden)

    guest = create_user(household: household, role: "guest")
    get "/api/v1/hook", headers: auth_headers(guest)
    expect(json).to eq("available" => false)

    stub_const("ENV", ENV.to_h.except("HOOK_URL", "HOOK_API_TOKEN"))
    get "/api/v1/hook", headers: auth_headers(member)
    expect(json).to eq("available" => false)
    get "/api/v1/hook/search", params: { kind: "movie", q: "arrival" }, headers: auth_headers(member)
    expect(json["errors"].sole).to start_with("Hook isn't connected")
  end

  it "searches Hook for films as the person asking, and says which Stream already has" do
    library = create_library(household: household, roots: build_root, name: "Movies")
    held = Movie.create!(household: household, library: library, title: "Arrival", year: 2016, tmdb_id: 329_865)
    stub_request(:get, "#{hook}/api/v1/search?media_kind=movie&q=arrival").with(headers: asked_by).to_return(json_body([
      { "provider" => "tmdb", "external_id" => "329865", "tmdb_id" => 329_865, "title" => "Arrival", "year" => 2016, "want_ids" => [] },
      { "provider" => "tmdb", "external_id" => "1", "tmdb_id" => 1, "title" => "Arrival II", "year" => 2030, "want_ids" => [ "w1" ] }
    ]))

    get "/api/v1/hook/search", params: { kind: "movie", q: "arrival" }, headers: auth_headers(member)

    expect(response).to have_http_status(:ok)
    expect(json.map { |hit| hit.slice("title", "in_stream_id", "requested") }).to eq([
      { "title" => "Arrival", "in_stream_id" => held.id, "requested" => false },
      { "title" => "Arrival II", "in_stream_id" => nil, "requested" => true }
    ])
  end

  it "searches shows as Hook's episode kind" do
    stub_request(:get, "#{hook}/api/v1/search?media_kind=episode&q=severance").to_return(json_body([
      { "provider" => "tmdb", "external_id" => "95396", "tmdb_id" => 95_396, "title" => "Severance", "network" => "Apple TV+" }
    ]))

    get "/api/v1/hook/search", params: { kind: "show", q: "severance" }, headers: auth_headers(member)

    expect(json.sole).to include("kind" => "show", "title" => "Severance", "network" => "Apple TV+", "in_stream_id" => nil)
  end

  it "wants a film, and records who asked" do
    want = stub_request(:post, "#{hook}/api/v1/wants").with(headers: asked_by,
      body: { media_kind: "movie", provider: "tmdb", external_id: "329865" }.to_json)
      .to_return(json_body({ "id" => "w1", "title" => "Arrival", "status" => "wanted", "explain" => "Hook is looking for it." }))

    post "/api/v1/hook/movies", params: { provider: "tmdb", external_id: "329865" }, headers: auth_headers(member)

    expect(response).to have_http_status(:created)
    expect(json).to eq("status" => "wanted", "explain" => "Hook is looking for it.")
    expect(want).to have_been_made.once
    expect(ActivityEntry.where(event: "request.movie").sole.summary).to eq("#{member.name} asked Hook for Arrival")
  end

  it "passes Hook's refusal on in its own words" do
    stub_request(:post, "#{hook}/api/v1/wants")
      .to_return(status: 422, body: { errors: [ "Arrival already has this version" ] }.to_json, headers: { "Content-Type" => "application/json" })

    post "/api/v1/hook/movies", params: { provider: "tmdb", external_id: "329865" }, headers: auth_headers(member)

    expect(response).to have_http_status(:unprocessable_content)
    expect(json["errors"]).to eq([ "Arrival already has this version" ])
  end

  it "says Hook didn't answer when it didn't" do
    stub_request(:get, %r{\A#{hook}/api/v1/search}).to_return(status: 503)

    get "/api/v1/hook/search", params: { kind: "movie", q: "arrival" }, headers: auth_headers(member)

    expect(response).to have_http_status(:bad_gateway)
    expect(json["errors"].sole).to eq("Hook returned 503")
  end

  it "adds a show and counts each season against what Stream already plays, specials last" do
    held = held_show(1 => [ 1, 2 ], 2 => [ 1 ])
    stub_request(:post, "#{hook}/api/v1/shows").with(body: { provider: "tmdb", external_id: "95396" }.to_json)
      .to_return(json_body(hook_show))

    post "/api/v1/hook/shows", params: { provider: "tmdb", external_id: "95396" }, headers: auth_headers(member)

    expect(response).to have_http_status(:ok)
    expect(json).to include("hook_show_id" => show_id, "title" => "Severance", "in_stream_id" => held.id, "following" => nil)
    expect(json["seasons"]).to eq([
      { "number" => 1, "episodes" => 2, "aired" => 2, "in_stream" => 2, "requested" => 0, "next_air_date" => nil },
      { "number" => 2, "episodes" => 2, "aired" => 1, "in_stream" => 1, "requested" => 1, "next_air_date" => "2026-11-06" },
      { "number" => 0, "episodes" => 1, "aired" => 1, "in_stream" => 0, "requested" => 0, "next_air_date" => nil }
    ])
  end

  it "wants each season chosen, then follows only what airs from today" do
    seasons = [ 1, 2 ].map do |number|
      stub_request(:post, "#{hook}/api/v1/shows/#{show_id}/want").with(headers: asked_by,
        body: { scope: "season", season_number: number }.to_json)
        .to_return(json_body({ "created" => 2, "already" => number == 2 ? 1 : 0, "show" => hook_show }))
    end
    stub_request(:get, "#{hook}/api/v1/monitors/schema?media_kind=episode&subject_type=Show").to_return(json_body({ "presets" => [
      { "key" => "new_releases", "rule" => { "when" => { "from" => "2026-10-19" }, "admission" => { "mode" => "auto" } } },
      { "key" => "everything", "rule" => { "kind" => { "episodes" => "all" } } }
    ] }))
    follow = stub_request(:put, "#{hook}/api/v1/shows/#{show_id}/follow")
      .with(body: { rule: { when: { from: "2026-10-19" }, admission: { mode: "auto" } } }.to_json)
      .to_return(json_body(hook_show(following: { "describe" => "New episodes from Oct 19, 2026" })))

    post "/api/v1/hook/shows/#{show_id}/want", params: { season_numbers: [ 2, 1 ], follow: "future" }, headers: auth_headers(member)

    expect(response).to have_http_status(:created)
    expect(json).to include("created" => 4, "already" => 1)
    expect(json["show"]["following"]).to eq("New episodes from Oct 19, 2026")
    expect(seasons).to all(have_been_made.once)
    expect(follow).to have_been_made.once
    expect(ActivityEntry.where(event: "request.show").sole.summary)
      .to eq("#{member.name} asked Hook for Severance: season 1 and season 2, and to follow its new episodes")
  end

  it "asks for something: a season or a follow" do
    post "/api/v1/hook/shows/#{show_id}/want", params: {}, headers: auth_headers(member)
    expect(json["errors"]).to eq([ "Choose a season or follow the show" ])

    post "/api/v1/hook/shows/#{show_id}/want", params: { follow: "sometimes" }, headers: auth_headers(member)
    expect(json["errors"]).to eq([ "Follow for new episodes or for everything" ])

    post "/api/v1/hook/shows/not-an-id/want", params: { season_numbers: [ 1 ] }, headers: auth_headers(member)
    expect(json["errors"]).to eq([ "That isn't one of Hook's shows" ])
  end

  it "tests the connection for an admin, naming who Hook takes them to be" do
    stub_request(:get, "#{hook}/api/v1/me").with(headers: { "Hook-On-Behalf-Of" => "sam@example.com" })
      .to_return(json_body({ "name" => "Sam" }))

    post "/api/v1/hook/test", headers: auth_headers(admin)
    expect(json).to eq("ok" => true, "message" => "Connected to Hook, asking as Sam")

    post "/api/v1/hook/test", headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
  end
end

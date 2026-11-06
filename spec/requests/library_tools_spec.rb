# typed: false
# frozen_string_literal: true

require "rails_helper"

# The smaller tools around the catalog: a file's page (re-running a step,
# correcting a marker), tagging titles for profiles, a profile's SponsorBlock
# choices, a title's transcript, and the household's people.
RSpec.describe "Library tools", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let!(:headers) { auth_headers(admin) }
  # The household's own profile first, so a kid made below isn't its default.
  let!(:everyone) { Profile.default_for(household) }
  let(:library) { create_library(household: household, roots: build_root, kind: "shows", name: "TV") }
  let(:show) { Show.create!(household: household, library: library, folder: "Office", title: "The Office") }
  let(:episode) do
    season = show.seasons.create!(season_number: 2)
    show.episodes.create!(season: season, season_number: 2, episode_number: 5, title: "Halloween").tap do |ep|
      ep.editions.create!(media_file: file)
    end
  end
  let(:file) do
    MediaFile.create!(household: household, library: library, path: "/tv/office.mkv", size: 1, mtime: Time.current, state: "probed",
      duration_seconds: 1300)
  end

  describe "a file's page" do
    before { episode }

    it "re-runs each analysis step through its own job" do
      jobs = {
        "probe" => ProbeMediaFileJob, "keyframes" => IndexKeyframesJob, "match" => MatchMediaFileJob, "artwork" => SyncArtworkJob,
        "trickplay" => AnalyzeMediaFileJob, "loudness" => AnalyzeMediaFileJob, "subtitle_fetch" => FetchSubtitlesJob,
        "transcript" => BuildTranscriptJob, "markers" => DetectMarkersJob, "subtitles" => AnalyzeMediaFileJob
      }
      # Optimize has its own spec; YouTube details is a video's (video_identity_spec).
      expect(jobs.keys + %w[optimize youtube_details]).to match_array(AnalysisRun::Step.values.map(&:serialize))

      jobs.each do |step, job|
        clear_enqueued_jobs # three steps share the one read's job
        post "/api/v1/media_files/#{file.id}/rerun", params: { step: step }, headers: headers
        expect(response).to have_http_status(:accepted), step
        expect(job).to have_been_enqueued, step
      end
      expect(file.reload.state).to eq("discovered") # a re-probe starts over

      post "/api/v1/media_files/#{file.id}/rerun", params: { step: "optimize" }, headers: headers
      expect(file.optimized_version).to have_attributes(state: "queued", origin: "manual")

      post "/api/v1/media_files/#{file.id}/rerun", params: { step: "everything" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(json["errors"]).to eq([ "Unknown step" ])
    end

    it "leaves a missing file missing when it's re-probed" do
      file.update!(state: "missing", missing_since: Time.current)

      post "/api/v1/media_files/#{file.id}/rerun", params: { step: "probe" }, headers: headers

      expect(response).to have_http_status(:accepted)
      expect(file.reload.state).to eq("missing")
      expect(ProbeMediaFileJob).to have_been_enqueued.with(file.id)
    end

    it "takes a person's marker over a detected one, refuses nonsense, and clears it" do
      Marker.offer(file, Marker::Kind::Intro, start: 5.0, finish: 30.0, source: Marker::Source::Chapter)

      put "/api/v1/media_files/#{file.id}/markers/intro", params: { start: "12.5", end: "41" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(json["markers"].sole).to include("kind" => "intro", "start" => 12.5, "end" => 41.0, "source" => "manual")

      [ { start: "41", end: "12" }, { start: "-1", end: "10" }, { start: "soon", end: "10" } ].each do |bad|
        put "/api/v1/media_files/#{file.id}/markers/intro", params: bad, headers: headers
        expect(json["errors"]).to eq([ "Start must come before end" ]), bad.inspect
      end
      put "/api/v1/media_files/#{file.id}/markers/opening", params: { start: "1", end: "2" }, headers: headers
      expect(json["errors"]).to eq([ "Unknown marker kind" ])

      delete "/api/v1/media_files/#{file.id}/markers/intro", headers: headers
      expect(json["markers"]).to eq([])
    end
  end

  describe "tagging titles for profiles" do
    it "tags and untags a title for a profile, and says who it's tagged for" do
      kid = Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 7)
      tag = ->(tagged) { put "/api/v1/profile_tags", params: { profile_id: kid.id, taggable_type: "show", taggable_id: show.id, tagged: tagged }, headers: headers }

      tag.call(true)
      tag.call(true)
      expect(json["profile_ids"]).to eq([ kid.id ])
      expect(ProfileTag.where(profile: kid).count).to eq(1)

      get "/api/v1/profile_tags", params: { taggable_type: "show", taggable_id: show.id }, headers: headers
      expect(json["profile_ids"]).to eq([ kid.id ])

      tag.call(false)
      expect(json["profile_ids"]).to eq([])

      put "/api/v1/profile_tags", params: { profile_id: kid.id, taggable_type: "person", taggable_id: show.id, tagged: true }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "SponsorBlock choices" do
    it "starts from the defaults and keeps a profile's own, ignoring unknown categories and actions" do
      get "/api/v1/sponsorblock_preferences", headers: headers
      expect(json["actions"]).to eq(SponsorSegment::DEFAULT_ACTIONS)

      patch "/api/v1/sponsorblock_preferences", params: { actions: { sponsor: "show", selfpromo: "explode", ads: "skip" } },
        headers: headers
      expect(json["actions"]).to include("sponsor" => "show", "selfpromo" => "ask")
      expect(json["actions"]).not_to have_key("ads")

      kid = Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 7)
      get "/api/v1/sponsorblock_preferences", headers: headers.merge(profile_header(kid))
      expect(json["actions"]["sponsor"]).to eq("skip") # each profile its own
    end
  end

  describe "viewing preferences" do
    it "keeps each profile's choice to autoplay videos, and shows it on the profile" do
      get "/api/v1/viewing_preferences", headers: headers
      expect(json).to eq("autoplay_videos" => false)

      patch "/api/v1/viewing_preferences", params: { autoplay_videos: true }, headers: headers
      expect(json).to eq("autoplay_videos" => true)
      get "/api/v1/profiles/current", headers: headers
      expect(json["profile"]["autoplay_videos"]).to be(true)

      kid = Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 7)
      get "/api/v1/viewing_preferences", headers: headers.merge(profile_header(kid))
      expect(json["autoplay_videos"]).to be(false) # each profile its own

      patch "/api/v1/viewing_preferences", params: {}, headers: headers
      expect(json["autoplay_videos"]).to be(true) # nothing given, nothing changed
    end
  end

  describe "a title's transcript" do
    it "has every line with its time once there is one, and nothing before" do
      get "/api/v1/transcript", params: { playable_type: "episode", playable_id: episode.id }, headers: headers
      expect(json).to eq("available" => false, "lines" => [])

      transcript = Transcript.create!(media_file: file, source: "subtitles", language: "en")
      TranscriptLine.create!(transcript: transcript, media_file: file, start_seconds: 1.0, end_seconds: 2.5, text: "Happy Halloween.")
      get "/api/v1/transcript", params: { playable_type: "episode", playable_id: episode.id }, headers: headers
      expect(json).to include("available" => true, "source" => "subtitles", "language" => "en",
        "lines" => [ { "start" => 1.0, "end" => 2.5, "text" => "Happy Halloween." } ])
    end

    it "keeps it from a profile that can't see the title" do
      show.update!(content_rating: "TV-14")
      kid = Profile.create!(household: household, name: "Kid", kind: "kid", max_rating_age: 7)

      get "/api/v1/transcript", params: { playable_type: "episode", playable_id: episode.id }, headers: headers.merge(profile_header(kid))

      expect(response).to have_http_status(:not_found)
    end
  end

  it "lists the household's people, oldest first, and no one else's" do
    member = create_user(household: household, email: "member@example.com")
    create_user(household: create_household(name: "Next door"), email: "neighbour@example.com")

    get "/api/v1/users", headers: headers

    expect(json.map { |user| user["email"] }).to eq([ admin.email, member.email ])
    expect(response.body).not_to include("password")
  end

  describe "the rest of the admin buttons" do
    let(:tube) { create_library(household: household, roots: build_root, kind: "channels", name: "YouTube") }

    it "switches SponsorBlock on for a channels library and asks for segments, and updates yt-dlp on request" do
      patch "/api/v1/youtube/sponsorblock", params: { library_id: tube.id, enabled: true }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(tube.reload.sponsorblock).to be(true)
      expect(RefreshSponsorSegmentsJob).to have_been_enqueued

      patch "/api/v1/youtube/sponsorblock", params: { library_id: library.id, enabled: true }, headers: headers
      expect(response).to have_http_status(:not_found) # not a channels library

      post "/api/v1/youtube/update_tool", headers: headers
      expect(response).to have_http_status(:accepted)
      expect(UpdateYtDlpJob).to have_been_enqueued
    end

    it "polls a tracked channel now, and says so when it isn't tracked" do
      channel = Channel.create!(household: household, library: tube, folder: "TC", title: "TC")
      post "/api/v1/channels/#{channel.id}/tracking/poll", headers: headers
      expect(json["errors"]).to eq([ "This channel isn't tracked" ])

      channel.update!(tracked: true, youtube_id: "UCy0tKL1T7wFoYcxCe0xjN6Q")
      post "/api/v1/channels/#{channel.id}/tracking/poll", headers: headers
      expect(response).to have_http_status(:accepted)
      expect(PollChannelJob).to have_been_enqueued.with(channel.id)
    end

    it "refreshes a title's metadata on request" do
      movie = Movie.create!(household: household, library: create_library(household: household, roots: build_root), title: "Heat")
      post "/api/v1/metadata/movie/#{movie.id}/refresh", headers: headers
      expect(response).to have_http_status(:accepted)
      expect(RefreshMetadataJob).to have_been_enqueued.with("Movie", movie.id)
    end
  end

  it "keeps a profile's own skip choices for a show, changing only what's sent" do
    patch "/api/v1/shows/#{show.id}/preferences", params: { skip_intro: true }, headers: headers
    expect(json).to eq("skip_intro" => true, "skip_recap" => false, "skip_credits" => false)
    patch "/api/v1/shows/#{show.id}/preferences", params: { skip_credits: true }, headers: headers
    expect(json).to eq("skip_intro" => true, "skip_recap" => false, "skip_credits" => true)

    kid = Profile.create!(household: household, name: "Kid", kind: "kid")
    patch "/api/v1/shows/#{show.id}/preferences", params: { skip_recap: true }, headers: headers.merge(profile_header(kid))
    expect(ShowPreference.find_by(profile: everyone, show: show)).to have_attributes(skip_recap: false)
  end

  it "offers home-video filters by album and face, with counts" do
    home = create_library(household: household, roots: build_root, kind: "home_videos", name: "Home")
    clip = ->(title, favorite: false) {
      Clip.create!(household: household, library: home, title: title, sort_title: title, captured_at: Time.current, captured_source: "immich",
        favorite: favorite).tap do |made|
        made.editions.create!(media_file: MediaFile.create!(household: household, library: home, path: "/h/#{title}.mp4", size: 1,
          mtime: Time.current, state: "probed"))
      end
    }
    beach = clip.call("Beach", favorite: true)
    party = clip.call("Party")
    summer = Album.create!(household: household, title: "Summer", immich_id: "a1")
    AlbumClip.create!(album: summer, clip: beach)
    ada = HomePerson.create!(household: household, immich_id: "p1", name: "Ada")
    [ beach, party ].each { |made| ClipPerson.create!(clip: made, home_person: ada) }

    get "/api/v1/clips/filters", params: { library_id: home.id }, headers: headers

    expect(json).to include("albums" => [ { "id" => summer.id, "title" => "Summer", "count" => 1 } ], "favorites" => 1)
    expect(json["people"].sole).to include("id" => ada.id, "name" => "Ada", "count" => 2)
  end
end

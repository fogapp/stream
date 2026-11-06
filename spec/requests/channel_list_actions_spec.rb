# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "A channel's row in the channels list", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:headers) { auth_headers(user) }
  let(:profile) { Profile.default_for(household) }
  let(:library) { create_library(household: household, roots: build_root, kind: "channels", name: "YouTube") }

  def channel(title, **attrs) = Channel.create!(household: household, library: library, folder: title, title: title, **attrs)

  def video(channel, title)
    Video.create!(household: household, library: library, channel: channel, title: title, upload_date: Date.new(2024, 1, 1), source: "folder").tap do |video|
      file = MediaFile.create!(household: household, library: library, path: "/v/#{title}.mkv", size: 1, mtime: Time.current,
        state: "probed", duration_seconds: 600)
      video.editions.create!(media_file: file)
    end
  end

  it "says whether this profile subscribes, whether it's followed, and where it is on YouTube" do
    tc = channel("Technology Connections", youtube_id: "UCy0tKL1T7wFoYcxCe0xjN6Q", url: "https://www.youtube.com/@TechnologyConnections",
      tracked: true)
    folder = channel("Home videos")
    video(tc, "Toasters")
    video(folder, "Birthday")
    ChannelSubscription.create!(profile: profile, channel: tc)

    get "/api/v1/channels", params: { library_id: library.id }, headers: headers
    rows = json.index_by { |row| row["title"] }
    expect(rows["Technology Connections"]).to include("subscribed" => true, "tracked" => true,
      "youtube_id" => "UCy0tKL1T7wFoYcxCe0xjN6Q", "url" => "https://www.youtube.com/@TechnologyConnections")
    expect(rows["Home videos"]).to include("subscribed" => false, "tracked" => false, "youtube_id" => nil, "url" => nil)
  end

  it "marks every video of a channel watched, and back" do
    tc = channel("Technology Connections")
    toasters = video(tc, "Toasters")
    dishwashers = video(tc, "Dishwashers")
    Playback::Progress.mark(profile, toasters, watched: true)
    plays = WatchState.find_by(profile: profile, playable: toasters).play_count

    post "/api/v1/channels/#{tc.id}/watched", headers: headers
    expect(response).to have_http_status(:no_content)
    expect(WatchState.where(profile: profile, playable: [ toasters, dishwashers ]).where.not(completed_at: nil).count).to eq(2)
    expect(WatchState.find_by(profile: profile, playable: toasters).play_count).to eq(plays)

    get "/api/v1/channels", params: { library_id: library.id }, headers: headers
    expect(json.first["unwatched_count"]).to eq(0)

    post "/api/v1/channels/#{tc.id}/watched", params: { watched: false }, headers: headers
    expect(WatchState.where(profile: profile, playable: [ toasters, dishwashers ]).where.not(completed_at: nil)).to be_empty
  end

  it "marks every video of a library watched, or just one channel's, and back" do
    tc = channel("Technology Connections")
    folder = channel("Home videos")
    toasters = video(tc, "Toasters")
    birthday = video(folder, "Birthday")
    elsewhere = create_library(household: household, roots: build_root, kind: "channels", name: "Other")
    other = Video.create!(household: household, library: elsewhere, channel: Channel.create!(household: household, library: elsewhere,
      folder: "Other", title: "Other"), title: "Other", source: "folder")

    post "/api/v1/videos/watched", params: { library_id: library.id, channel_id: folder.id }, headers: headers
    expect(response).to have_http_status(:no_content)
    expect(WatchState.where(profile: profile).where.not(completed_at: nil).map(&:playable)).to eq([ birthday ])

    post "/api/v1/videos/watched", params: { library_id: library.id }, headers: headers
    expect(WatchState.where(profile: profile).where.not(completed_at: nil).map(&:playable)).to contain_exactly(toasters, birthday)
    expect(WatchState.find_by(profile: profile, playable: other)).to be_nil

    post "/api/v1/videos/watched", params: { library_id: library.id, watched: false }, headers: headers
    expect(WatchState.where(profile: profile).where.not(completed_at: nil)).to be_empty

    post "/api/v1/videos/watched", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
  end
end

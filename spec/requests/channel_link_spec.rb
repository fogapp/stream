# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Linking a folder's channel to YouTube", type: :request do
  let(:household) { create_household }
  let(:admin) { create_user(household: household, role: "admin") }
  let(:member) { create_user(household: household) }
  let(:library) { create_library(household: household, roots: build_root, kind: "channels", name: "YouTube") }
  let(:channel) { Channel.create!(household: household, library: library, folder: "Funhaus", title: "Funhaus") }
  let(:channel_id) { "UCboMX_UNgaPBsUOIgasn3-Q" }
  let(:listing) do
    { "_type" => "playlist", "channel" => "Funhaus", "channel_id" => channel_id, "uploader_id" => "@FUNHAUS",
      "description" => "Funhaus is a comedy gaming channel.",
      "thumbnails" => [ { "id" => "avatar_uncropped", "url" => "https://yt3.ggpht.com/av" },
                        { "id" => "banner_uncropped", "url" => "https://yt3.googleusercontent.com/ban" } ],
      "entries" => [] }
  end

  def link(url, as: admin) = post "/api/v1/channels/#{channel.id}/tracking/link", params: { url: url }, headers: auth_headers(as), as: :json

  it "fills in the channel from YouTube and looks up its videos, without following it" do
    expect(Youtube::YtDlp).to receive(:json).with("https://www.youtube.com/@FUNHAUS/videos", anything).and_return(listing)

    link("https://www.youtube.com/@FUNHAUS")

    expect(response).to have_http_status(:ok)
    expect(json).to include("tracked" => false)
    expect(channel.reload).to have_attributes(youtube_id: channel_id, handle: "@FUNHAUS", tracked: false,
      avatar_url: "https://yt3.ggpht.com/av", banner_url: "https://yt3.googleusercontent.com/ban",
      description: "Funhaus is a comedy gaming channel.", url: "https://www.youtube.com/channel/#{channel_id}")
    jobs = enqueued_jobs.map { |job| [ job["job_class"], job["arguments"].last ] }
    expect(jobs).to include([ "IdentifyChannelVideosJob", channel.id ], [ "SyncArtworkJob", channel.id ])
    expect(enqueued_jobs.map { |job| job["job_class"] }).not_to include("PollChannelJob")

    get "/api/v1/channels/#{channel.id}", headers: auth_headers(admin)
    expect(json).to include("youtube_id" => channel_id, "handle" => "@FUNHAUS")

    link("https://www.youtube.com/@FUNHAUS")
    expect(json).to eq("errors" => [ "Funhaus is already linked to YouTube" ])
  end

  it "keeps a name someone gave the channel, and refuses anything but a channel no other channel is" do
    channel.update!(title: "Funhaus (the good years)")
    allow(Youtube::YtDlp).to receive(:json).and_return(listing)

    link("https://www.youtube.com/watch?v=YAXRQExOi04")
    expect(json).to eq("errors" => [ "Paste the channel's link, like youtube.com/@name" ])
    link("https://vimeo.com/123")
    expect(json).to eq("errors" => [ "That isn't a YouTube link" ])

    other = Channel.create!(household: household, library: library, folder: "FH", title: "FH", youtube_id: channel_id)
    link("https://www.youtube.com/@FUNHAUS")
    expect(response).to have_http_status(:conflict)
    expect(json).to eq("errors" => [ "#{other.title} is already that channel" ])

    other.destroy!
    link("https://www.youtube.com/@FUNHAUS")
    expect(channel.reload).to have_attributes(title: "Funhaus (the good years)", youtube_id: channel_id)
  end

  it "says what YouTube said when it won't answer, and is for admins" do
    allow(Youtube::YtDlp).to receive(:json).and_raise(Youtube::YtDlp::Error, "Sign in to confirm you're not a bot")
    link("https://www.youtube.com/@FUNHAUS")
    expect(json).to eq("errors" => [ "Sign in to confirm you're not a bot" ])
    expect(channel.reload.youtube_id).to be_nil

    link("https://www.youtube.com/@FUNHAUS", as: member)
    expect(response).to have_http_status(:forbidden)
  end
end

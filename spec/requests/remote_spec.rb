# typed: false
# frozen_string_literal: true

require "rails_helper"

# Playing to another screen from the app's side (PROPOSAL §11 Phase 6): a
# browser opts in and names itself, polls for commands and gets each once;
# another browser sends it one.
RSpec.describe "Remote control", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }

  def as_device(key) = auth_headers(user).merge("X-Stream-Device" => key)

  it "lets a browser name itself, opt in, and pick up each command once" do
    get "/api/v1/remote/commands", headers: as_device("tv-1")
    expect(json).to eq([])

    patch "/api/v1/remote/this_device", params: { label: "Living room", remote_control: true }, headers: as_device("tv-1")
    expect(json).to include("name" => "Living room", "remote_control" => true)
    get "/api/v1/remote/commands", headers: as_device("tv-1")
    tv = Device.find_by(client_key: "tv-1")
    expect(tv).to be_listening

    root = build_root("Heat.mp4" => "h264_aac.mp4")
    library = create_library(household: household, roots: root)
    movie = Movie.create!(household: household, library: library, title: "Heat")
    movie.editions.create!(media_file: MediaFile.create!(household: household, library: library, path: File.join(root, "Heat.mp4"),
      size: 1, mtime: Time.current, state: "probed"))

    get "/api/v1/remote/devices", headers: as_device("phone")
    expect(json.sole).to include("id" => tv.id, "name" => "Living room", "listening" => true)
    post "/api/v1/remote/devices/#{tv.id}/commands", params: { kind: "play", playable_type: "movie", playable_id: movie.id },
      headers: as_device("phone")
    expect(response).to have_http_status(:created)
    post "/api/v1/remote/devices/#{tv.id}/commands", params: { kind: "pause" }, headers: as_device("phone")

    get "/api/v1/remote/commands", headers: as_device("tv-1")
    expect(json.map { |command| command["kind"] }).to eq(%w[play pause])
    expect(json.first["payload"]).to include("kind" => "movie", "id" => movie.id, "title" => "Heat")
    get "/api/v1/remote/commands", headers: as_device("tv-1")
    expect(json).to eq([])
  end

  it "drops a command nobody picked up within a minute" do
    tv = Device.create!(household: household, client_key: "tv-1", name: "TV", remote_control: true, remote_seen_at: Time.current,
      last_seen_at: Time.current)
    Remote::Control.send_command(tv, DeviceCommand::Kind::Pause).update!(expires_at: 1.second.ago)
    get "/api/v1/remote/commands", headers: as_device("tv-1")
    expect(json).to eq([])
  end

  it "copes with this browser's device being made by another request a moment before" do
    root = build_root("Heat.mp4" => "h264_aac.mp4")
    library = create_library(household: household, roots: root)
    movie = Movie.create!(household: household, library: library, title: "Heat")
    file = MediaFile.create!(household: household, library: library, path: File.join(root, "Heat.mp4"), size: 1, mtime: Time.current,
      state: "discovered")
    Media::FileProber.new(file).call
    movie.editions.create!(media_file: file)
    # The race: the device appears between the lookup and the save.
    allow(Device).to receive(:find_or_initialize_by) do |**attributes|
      Device.create!(household: household, client_key: attributes[:client_key], name: "TV", last_seen_at: Time.current)
      Device.new(attributes.merge(household_id: household.id))
    end

    post "/api/v1/playback_sessions", params: { playable_type: "movie", playable_id: movie.id, device_key: "tv-1",
      capabilities: { "video" => %w[h264], "audio" => %w[aac] } }, headers: as_device("tv-1")
    expect(response).to have_http_status(:created)
    expect(Device.where(client_key: "tv-1").count).to eq(1)
  end
end

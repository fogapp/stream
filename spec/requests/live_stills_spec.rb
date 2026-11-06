# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Live stream stills", type: :request do
  let(:household) { create_household }
  let(:user) { create_user(household: household) }
  let(:library) { Library.create!(household: household, name: "Cameras", kind: "live") }
  let(:stream) do
    LiveStream.create!(household: household, library: library, name: "Front door", kind: "camera",
      url: "rtsps://192.168.1.1:7441/AbCdEfGhIjKlMnOp?enableSrtp", still_at: Time.current)
  end

  around do |example|
    Dir.mktmpdir("stream-cache") do |cache|
      @cache = cache
      example.run
    end
  end

  before do
    stub_const("ENV", ENV.to_h.merge("STREAM_CACHE_DIR" => @cache))
    FileUtils.mkdir_p(LiveStreams::Still.root)
    LiveStreams::Still.path(stream.id).binwrite("RIFFwebp")
  end

  it "serves a card's picture by its signed URL, to an <img> with no session, and nothing without one" do
    get "/api/v1/live_streams", headers: auth_headers(user)
    url = json.sole["still_url"]

    get url
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/webp")
    expect(response.body).to eq("RIFFwebp")

    get url.sub(/s=\h+/, "s=#{'0' * 24}")
    expect(response).to have_http_status(:not_found)
  end

  it "goes when its stream does" do
    stream.destroy!
    expect(LiveStreams::Still.path(stream.id)).not_to exist
  end

  it "lists streams that stopped answering on the Playback page" do
    admin = create_user(household: household, role: "admin")
    stream.update!(status: "offline", last_error: "Nothing answered at rtsps://192.168.1.1:7441")

    get "/api/v1/playback_decisions/health", headers: auth_headers(admin)
    check = json["checks"].find { |candidate| candidate["key"] == "live_streams" }
    expect(check).to include("status" => "act", "metric" => "0/1", "link" => { "path" => "/library/#{library.id}" })
    expect(check["detail"]).to include("Front door isn't answering: Nothing answered at rtsps://192.168.1.1:7441")
  end
end

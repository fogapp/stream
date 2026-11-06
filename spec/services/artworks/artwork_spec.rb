# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Artwork" do
  before do
    require_ffprobe!
    @storage = Dir.mktmpdir("stream-storage")
    stub_const("ENV", ENV.to_h.merge("STREAM_STORAGE_DIR" => @storage))
  end

  after { FileUtils.rm_rf(@storage) }

  let(:household) { Household.create!(name: "Art") }
  let(:library) { create_library(household: household, roots: build_root) }

  # ffmpeg averages in YUV, so a colour comes back within a few units.
  def near_color(hex)
    want = hex.delete("#").scan(/../).map { |c| c.to_i(16) }
    satisfy("be within 8 of #{hex} per channel") do |got|
      got.delete("#").scan(/../).map { |c| c.to_i(16) }.zip(want).all? { |a, b| (a - b).abs <= 8 }
    end
  end

  # A real 1000x1500 PNG, the shape of a TMDB poster.
  def poster_png
    path = File.join(Dir.mktmpdir, "poster.png")
    ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i color=c=0x3366cc:s=1000x1500 -frames:v 1 #{path}])
    File.binread(path)
  end

  describe Artworks::Renderer do
    it "renders each width, never upscaling, with a placeholder and an average colour" do
      source = File.join(Dir.mktmpdir, "logo.png")
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i color=c=0xff0000:s=400x100 -frames:v 1 #{source}])
      into = Pathname.new(Dir.mktmpdir)

      result = described_class.render(source, into: into, widths: [ 300, 500 ], alpha: true)

      expect(result).to have_attributes(width: 400, height: 100, widths: [ 300, 500 ])
      expect(result.placeholder).to start_with("data:image/webp;base64,")
      expect(result.color).to near_color("#ff0000")
      expect(into.join("300.webp")).to be_file
      # 500 would upscale a 400px source, so that slot holds the full-size render.
      expect(into.join("500.webp")).to be_file
    end

    it "raises a readable error for something that isn't an image" do
      junk = File.join(Dir.mktmpdir, "junk.jpg").tap { |path| File.write(path, "not an image") }
      expect { described_class.render(junk, into: Pathname.new(Dir.mktmpdir), widths: [ 185 ]) }
        .to raise_error(Artworks::Renderer::Error)
    end
  end

  describe Artworks::Sync do
    let(:movie) { Movie.create!(household: household, library: library, title: "Heat", poster_path: "/heat.jpg") }

    it "downloads, renders and publishes a TMDB poster once" do
      stub = stub_request(:get, "https://image.tmdb.org/t/p/w780/heat.jpg").to_return(status: 200, body: poster_png)

      described_class.new(movie).call
      described_class.new(movie).call

      artwork = Artwork.sole
      expect(artwork).to have_attributes(kind: "poster", state: "ready", version: 1, width: 1000, height: 1500,
        rendered_widths: [ 185, 342, 500 ], color: near_color("#3366cc"))
      expect(artwork.file_for(342)).to be_file
      expect(stub).to have_been_requested.once
    end

    it "re-renders into a new version when the source changes, removing the old one" do
      stub_request(:get, %r{image.tmdb.org}).to_return(status: 200, body: poster_png)
      described_class.new(movie).call
      old_file = Artwork.sole.file_for(185)

      movie.update!(poster_path: "/heat-new.jpg")
      described_class.new(movie).call

      expect(Artwork.sole).to have_attributes(version: 2, source_ref: "/heat-new.jpg")
      expect(old_file).not_to exist
    end

    it "keeps a failed render's error on the row and says so" do
      stub_request(:get, %r{image.tmdb.org}).to_return(status: 404)
      described_class.new(movie).call

      expect(Artwork.sole).to have_attributes(state: "failed", consecutive_failures: 1, last_error: include("404"))
      expect(ActivityEntry.where(event: "artwork.failed").count).to eq(1)
    end

    it "refuses a path that isn't TMDB's shape" do
      movie.update!(poster_path: "/../../etc/passwd")
      described_class.new(movie).call
      expect(Artwork.sole.state).to eq("failed")
      expect(a_request(:get, /tmdb/)).not_to have_been_made
    end
  end

  describe Artworks::FrameGrab do
    it "gives an unpictured movie a frame from its file" do
      root = build_root("Home (2019)/Home.mkv" => "h264_aac.mp4")
      file = MediaFile.create!(household: household, library: create_library(household: household, roots: root),
        path: File.join(root, "Home (2019)/Home.mkv"), size: 1, mtime: Time.current, state: "probed", duration_seconds: 2.0)
      movie = Movie.create!(household: household, library: file.library, title: "Home")
      movie.editions.create!(media_file: file)

      described_class.new(movie).call

      expect(Artwork.sole).to have_attributes(kind: "thumb", source: "frame", source_ref: file.id, state: "ready", width: 160)
      expect(file.analysis_runs.sole).to have_attributes(step: "artwork", status: "succeeded")
    end

    it "records a frame that times out on the row and the file, then stops asking" do
      root = build_root("Slow (2019)/Slow.mkv" => "h264_aac.mp4")
      file = MediaFile.create!(household: household, library: create_library(household: household, roots: root),
        path: File.join(root, "Slow (2019)/Slow.mkv"), size: 1, mtime: Time.current, state: "probed", duration_seconds: 2.0)
      movie = Movie.create!(household: household, library: file.library, title: "Slow")
      movie.editions.create!(media_file: file)
      allow(ToolRunner).to receive(:run).and_call_original
      allow(ToolRunner).to receive(:run).with(array_including("0:V:0"), timeout: Artworks::Renderer::FRAME_TIMEOUT)
        .and_raise(ToolRunner::Timeout, "ffmpeg exceeded 300s")

      expect { described_class.new(movie).call }.not_to raise_error
      expect(Artwork.sole).to have_attributes(state: "failed", last_error: "ffmpeg exceeded 300s", consecutive_failures: 1)
      expect(file.analysis_runs.sole).to have_attributes(status: "failed", error: "ToolRunner::Timeout: ffmpeg exceeded 300s")

      Artwork.sole.update!(consecutive_failures: Artwork::GIVE_UP_AFTER)
      described_class.new(movie).call
      expect(ToolRunner).to have_received(:run).with(array_including("0:V:0"), anything).once
    end
  end

  describe "serving", type: :request do
    it "serves a signed URL with immutable caching and refuses a forged one" do
      stub_request(:get, %r{image.tmdb.org}).to_return(status: 200, body: poster_png)
      movie = Movie.create!(household: household, library: library, title: "Heat", poster_path: "/heat.jpg")
      Artworks::Sync.new(movie).call
      artwork = Artwork.sole

      get ArtworkUrl.for(artwork, 342)
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/webp")
      expect(response.headers["Cache-Control"]).to include("immutable")

      get "/artwork/#{artwork.id}/#{artwork.version}/342.webp?s=0000"
      expect(response).to have_http_status(:not_found)
      get ArtworkUrl.for(artwork, 999)
      expect(response).to have_http_status(:not_found)
    end

    it "builds srcsets for a page of owners in one query" do
      stub_request(:get, %r{image.tmdb.org}).to_return(status: 200, body: poster_png)
      movies = Array.new(3) { |i| Movie.create!(household: household, library: library, title: "M#{i}", poster_path: "/m#{i}.jpg") }
      movies.each { |movie| Artworks::Sync.new(movie).call }

      index = nil
      expect(count_queries(matching: /artworks/) { index = ArtworkSerializer.index(movies) }.size).to eq(1)
      poster = ArtworkSerializer.images(index, movies.first)["poster"]
      expect(poster[:srcset].split(", ").size).to eq(3)
      expect(poster[:placeholder]).to start_with("data:image/webp")
    end
  end

  # Pictures beside the media, and the channel and face pictures fetched for
  # them: read where they are, rendered into storage (never beside the media).
  describe "the other sources" do
    let(:channels) { create_library(household: household, roots: build_root, kind: "channels", name: "YouTube") }
    let(:channel) { Channel.create!(household: household, library: channels, folder: "TC", title: "TC") }

    def png(path, color = "0x3366cc")
      FileUtils.mkdir_p(File.dirname(path))
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i color=c=#{color}:s=320x180 -frames:v 1 -f image2 -c:v png #{path}])
      path
    end

    describe Artworks::Local do
      it "takes a video's thumbnail and a channel's avatar and banner from beside them, once" do
        root = channels.roots.first
        path = File.join(root, "TC", "Talk [aaaaaaaaaaa].mkv")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "v")
        png(path.sub(".mkv", ".png"))
        png(File.join(root, "TC", "folder.png"))
        png(File.join(root, "TC", "banner.png"), "0xcc3333")
        file = MediaFile.create!(household: household, library: channels, path: path, size: 1, mtime: Time.current, state: "probed")
        video = Video.create!(household: household, library: channels, channel: channel, title: "Talk", source: "folder")
        video.editions.create!(media_file: file)
        settle_library_roots!

        described_class.new(video).call
        described_class.new(channel).call

        expect(Artwork.find_by(owner: video, kind: "thumb")).to have_attributes(state: "ready", source: "local")
        expect(Artwork.where(owner: channel).pluck(:kind, :state).sort).to eq([ %w[backdrop ready], %w[profile ready] ])
        expect(Artwork.find_by(owner: channel, kind: "backdrop").color).to near_color("#cc3333")

        allow(Artworks::Publish).to receive(:call)
        described_class.new(channel).call
        expect(Artworks::Publish).not_to have_received(:call) # unchanged on disk: nothing to do
      end

      it "records a picture it can't read, and finds nothing for a channel with no folder" do
        root = channels.roots.first
        FileUtils.mkdir_p(File.join(root, "TC"))
        File.write(File.join(root, "TC", "avatar.jpg"), "not a picture")
        settle_library_roots!

        described_class.new(channel).call

        expect(Artwork.find_by(owner: channel, kind: "profile")).to have_attributes(state: "failed", last_error: be_present)
        elsewhere = Channel.create!(household: household, library: channels, folder: "Nowhere", title: "Nowhere")
        expect(described_class.new(elsewhere).wanted).to eq({})
      end
    end

    describe Artworks::YoutubeImages do
      it "fetches a channel's pictures only from YouTube's image hosts" do
        channel.update!(avatar_url: "https://yt3.ggpht.com/avatar=s900", banner_url: "https://evil.example/banner.jpg")
        stub_request(:get, "https://yt3.ggpht.com/avatar=s900").to_return(status: 200, body: File.binread(png(File.join(Dir.mktmpdir, "a.png"))))

        described_class.sync(channel)

        expect(Artwork.find_by(owner: channel, kind: "profile")).to have_attributes(state: "ready", source: "youtube")
        expect(Artwork.find_by(owner: channel, kind: "backdrop")).to have_attributes(state: "failed",
          last_error: a_string_including("not a YouTube image"))
        expect(WebMock).not_to have_requested(:get, /evil\.example/)
      end

      it "leaves a picture from disk alone" do
        Artwork.create!(owner: channel, kind: "profile", source: "local", state: "ready", source_ref: "x")
        channel.update!(avatar_url: "https://yt3.ggpht.com/avatar=s900")

        described_class.sync(channel)

        expect(WebMock).not_to have_requested(:get, /ggpht/)
      end
    end

    describe Artworks::ImmichFaces do
      let(:person) { HomePerson.create!(household: household, immich_id: "p1", name: "Ada") }

      it "renders a face from Immich once, and records a failure" do
        ImmichSetting.create!(household: household, url: "http://immich.lan:2283", api_key: "k", local_path_prefix: build_root)
        face = stub_request(:get, "http://immich.lan:2283/api/people/p1/thumbnail")
          .to_return(status: 200, body: File.binread(png(File.join(Dir.mktmpdir, "f.png"))))

        2.times { described_class.sync(person) }

        expect(face).to have_been_requested.once
        expect(Artwork.find_by(owner: person)).to have_attributes(state: "ready", source: "immich", source_ref: "p1")

        other = HomePerson.create!(household: household, immich_id: "p2", name: "Grace")
        stub_request(:get, "http://immich.lan:2283/api/people/p2/thumbnail").to_return(status: 404, body: "{}")
        described_class.sync(other)
        expect(Artwork.find_by(owner: other)).to have_attributes(state: "failed", last_error: be_present)
      end

      it "does nothing without Immich set up" do
        described_class.sync(person)
        expect(Artwork.count).to eq(0)
      end
    end
  end
end

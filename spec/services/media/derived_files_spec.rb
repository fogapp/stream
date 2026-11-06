# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Media::DerivedFiles do
  include RequestHelpers
  before do
    @dirs = [ Dir.mktmpdir("stream-storage"), Dir.mktmpdir("stream-cache") ]
    stub_const("ENV", ENV.to_h.merge("STREAM_STORAGE_DIR" => @dirs.first, "STREAM_CACHE_DIR" => @dirs.last))
  end

  after { FileUtils.rm_rf(@dirs) }

  let(:household) { create_household }
  let(:library) { create_library(household: household, roots: build_root) }

  def file(name)
    MediaFile.create!(household: household, library: library, path: File.join(library.roots.first, name), size: 1,
      mtime: Time.current, state: "probed")
  end

  def made_from(media_file)
    [ Trickplay.root.join(media_file.id, "1"), Subtitles::Extractor.root.join(media_file.id) ].each(&:mkpath)
    version = OptimizedVersion.create!(household: household, media_file: media_file, state: "ready")
    version.path.dirname.mkpath
    FileUtils.touch(version.path)
    [ Trickplay.root.join(media_file.id), Subtitles::Extractor.root.join(media_file.id), version.path ]
  end

  it "sweeps up what was made from a deleted library's files, and nothing else" do
    kept = made_from(file("Kept.mkv"))
    other = create_library(household: household, roots: build_root, name: "Other")
    gone = made_from(MediaFile.create!(household: household, library: other, path: File.join(other.roots.first, "Gone.mkv"),
      size: 1, mtime: Time.current, state: "probed"))
    stray = Trickplay.root.join("not-an-id").tap(&:mkpath)

    other.destroy!
    expect(gone).to all(exist)
    expect(described_class.sweep).to eq(3)

    expect(gone).to all(satisfy { |path| !path.exist? })
    expect(kept).to all(exist)
    expect(stray).to exist
  end

  it "takes a file's subtitles and thumbnails with it" do
    media_file = file("Purged.mkv")
    trickplay, subtitles, = made_from(media_file)
    media_file.destroy!
    expect(trickplay).not_to exist
    expect(subtitles).not_to exist
  end
end

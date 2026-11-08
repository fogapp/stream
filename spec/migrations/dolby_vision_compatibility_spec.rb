# typed: false
# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261108130100_add_dolby_vision_compatibility_to_media_streams")

# Decision reads a Dolby Vision base layer's compatibility and a stream's
# codec tag from its row: the probe keeps them as it reads a file, and the
# rows probed before were filled from what the probe stored, as Decision
# used to read it at play time.
RSpec.describe AddDolbyVisionCompatibilityToMediaStreams do
  let(:household) { Household.create!(name: "DV") }
  let(:library) { create_library(household: household, roots: build_root) }

  def dovi(compatibility)
    { "side_data_type" => "DOVI configuration record", "dv_profile" => 8, "dv_bl_signal_compatibility_id" => compatibility }
  end

  it "keeps what the probe saw on each stream's row" do
    streams = Media::Probe.streams_from("streams" => [
      { "index" => 0, "codec_type" => "video", "codec_name" => "hevc", "codec_tag_string" => "dvhe", "side_data_list" => [ dovi(4) ] },
      { "index" => 1, "codec_type" => "audio", "codec_name" => "eac3", "codec_tag_string" => "" }
    ])
    expect(streams.map { |row| row.slice(:dolby_vision_profile, :dolby_vision_compatibility, :codec_tag) }).to eq([
      { dolby_vision_profile: 8, dolby_vision_compatibility: 4, codec_tag: "dvhe" },
      { dolby_vision_profile: nil, dolby_vision_compatibility: nil, codec_tag: nil }
    ])
  end

  it "fills the rows probed before from the stored probe, and leaves a row that already says alone" do
    probe = { "streams" => [
      { "index" => 0, "codec_tag_string" => "hev1", "side_data_list" => [ { "side_data_type" => "Mastering display metadata" }, dovi(4) ] },
      { "index" => 1, "codec_tag_string" => "" }, { "index" => 2, "codec_tag_string" => "mp4a" }
    ] }
    file = MediaFile.create!(household: household, library: library, path: "/m/dv.mkv", size: 1, mtime: Time.current, state: "probed", probe: probe)
    video = file.media_streams.create!(index: 0, kind: "video", codec: "hevc")
    silent = file.media_streams.create!(index: 1, kind: "audio", codec: "aac")
    tagged = file.media_streams.create!(index: 2, kind: "audio", codec: "aac", codec_tag: "kept")
    other = MediaFile.create!(household: household, library: library, path: "/m/sdr.mkv", size: 1, mtime: Time.current, state: "probed",
      probe: { "streams" => [ { "index" => 0, "side_data_list" => [ dovi("x") ] } ] })
    unreadable = other.media_streams.create!(index: 0, kind: "video", codec: "hevc")
    MediaFile.create!(household: household, library: library, path: "/m/odd.mkv", size: 1, mtime: Time.current, state: "probed",
      probe: { "streams" => "not a list" })

    migration = described_class.new
    migration.verbose = false
    migration.backfill_codec_tags
    migration.backfill_dolby_vision

    expect(video.reload).to have_attributes(codec_tag: "hev1", dolby_vision_compatibility: 4)
    expect(silent.reload).to have_attributes(codec_tag: nil, dolby_vision_compatibility: nil)
    expect(tagged.reload.codec_tag).to eq("kept")
    expect(unreadable.reload.dolby_vision_compatibility).to be_nil
  end
end

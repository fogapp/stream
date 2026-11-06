# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Playback::Encoders do
  after { described_class.instance_variable_set(:@avx2, nil) }

  it "allows two software conversions with AVX2 and one without (spikes.md › C)" do
    allow(described_class).to receive(:kind).and_return(described_class::Kind::Software)

    described_class.instance_variable_set(:@avx2, true)
    expect(described_class.default_cap).to eq(2)

    described_class.instance_variable_set(:@avx2, false)
    expect(described_class.default_cap).to eq(1)
  end

  it "allows three on the iGPU" do
    allow(described_class).to receive(:kind).and_return(described_class::Kind::Vaapi)
    expect(described_class.default_cap).to eq(3)
  end

  # docs/PERF_PROPOSAL.md › P5: an ffmpeg test encode never runs in a press of Play.
  it "reads what the transcoder's probe found, and never probes itself" do
    store = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(store)
    allow(described_class).to receive(:probe).and_return(described_class::Kind::Vaapi)

    expect(described_class.kind).to eq(described_class::Kind::Software)
    expect(described_class).not_to have_received(:probe)

    expect(described_class.probe!).to eq(described_class::Kind::Vaapi)
    expect(described_class.kind).to eq(described_class::Kind::Vaapi)
  end

  it "prefers the limit set in Settings" do
    AppSetting.current.update!(max_video_transcodes: 4)
    expect(described_class.cap).to eq(4)
  end
end

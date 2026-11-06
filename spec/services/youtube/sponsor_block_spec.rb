# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "SponsorBlock" do
  let(:household) { Household.create!(name: "Sponsor") }
  let(:library) { create_library(household: household, roots: build_root, kind: "channels", name: "YouTube").tap { |l| l.update!(sponsorblock: true) } }
  let(:channel) { Channel.create!(household: household, library: library, folder: "TC", title: "TC") }
  let(:video) { Video.create!(household: household, library: library, channel: channel, title: "Talk", youtube_id: "Ql7w1yX7hbI", source: "info_json") }
  let(:prefix) { Digest::SHA256.hexdigest("Ql7w1yX7hbI")[0, 4] }

  def stub_segments(body, status: 200)
    stub_request(:get, %r{\Ahttps://sponsor\.ajay\.app/api/skipSegments/#{prefix}\?})
      .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  it "asks by hash prefix, keeps only this video's skip segments, and replaces them on the next ask" do
    stub_segments([
      { "videoID" => "someoneElse", "segments" => [ { "category" => "sponsor", "segment" => [ 1, 2 ], "UUID" => "x" } ] },
      { "videoID" => "Ql7w1yX7hbI", "segments" => [
        { "category" => "sponsor", "segment" => [ 30.5, 90.0 ], "UUID" => "a", "actionType" => "skip" },
        { "category" => "interaction", "segment" => [ 400, 410 ], "UUID" => "b", "actionType" => "skip" },
        { "category" => "chapter", "segment" => [ 0, 5 ], "UUID" => "c" }
      ] }
    ])

    FetchSponsorSegmentsJob.perform_now(video.id)

    expect(video.sponsor_segments.map { |s| [ s.category, s.start_seconds, s.end_seconds ] }).to eq([ [ "sponsor", 30.5, 90.0 ], [ "interaction", 400.0, 410.0 ] ])
    expect(video.reload.sponsorblock_checked_at).to be_present

    stub_segments([], status: 404)
    FetchSponsorSegmentsJob.perform_now(video.id)
    expect(video.sponsor_segments.reload).to be_empty
  end

  it "does nothing for a library that hasn't turned it on" do
    library.update!(sponsorblock: false)
    FetchSponsorSegmentsJob.perform_now(video.id)
    expect(WebMock).not_to have_requested(:get, /sponsor\.ajay\.app/)
  end

  it "gives each profile its own action per category, sponsors skipped by default" do
    profile = Profile.default_for(household)
    expect(SponsorSegment.actions_for(profile)).to include("sponsor" => "skip", "selfpromo" => "ask", "filler" => "show")
    profile.update!(sponsorblock: { "sponsor" => "ask", "selfpromo" => "skip", "nonsense" => "skip", "filler" => "explode" })
    expect(SponsorSegment.actions_for(profile)).to include("sponsor" => "ask", "selfpromo" => "skip", "filler" => "show")
    expect(SponsorSegment.actions_for(profile)).not_to have_key("nonsense")
  end
end

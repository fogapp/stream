# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Playback::StreamToken do
  let(:household) { Household.create!(name: "T") }
  let(:session) do
    library = create_library(household: household, roots: build_root)
    file = MediaFile.create!(household: household, library: library, path: "/x.mp4", size: 1, mtime: Time.current, state: "probed")
    movie = Movie.create!(household: household, library: library, title: "X")
    PlaybackSession.create!(household: household, profile: Profile.default_for(household), playable: movie,
      media_file: file, method: "direct", started_at: Time.current, last_seen_at: Time.current)
  end

  it "round-trips an active session" do
    expect(described_class.verify(described_class.issue(session))).to eq(session)
  end

  it "rejects a token past its lifetime" do
    token = described_class.issue(session, now: 7.hours.ago)
    expect(described_class.verify(token)).to be_nil
  end

  it "rejects a tampered expiry or session" do
    id, expires, signature = described_class.issue(session).split(".")
    expect(described_class.verify("#{id}.#{expires.to_i + 86_400}.#{signature}")).to be_nil
    expect(described_class.verify("#{SecureRandom.uuid}.#{expires}.#{signature}")).to be_nil
    expect(described_class.verify("garbage")).to be_nil
  end

  it "stops working when the session ends" do
    token = described_class.issue(session)
    session.end!
    expect(described_class.verify(token)).to be_nil
  end

  it "is signed with STREAM_TOKEN_KEY when set, so rotating it revokes everything" do
    token = described_class.issue(session)
    stub_const("ENV", ENV.to_h.merge("STREAM_TOKEN_KEY" => "rotated"))
    expect(described_class.verify(token)).to be_nil
  end

  # The three token-in-the-path surfaces share one key (CLAUDE.md): each
  # signs its own kind of row, so one never opens another's door — even
  # for rows that happen to share an id.
  describe "beside download and run tokens" do
    let(:download) do
      OfflineDownload.create!(household: household, profile: session.profile, playable: session.playable, media_file: session.media_file,
        size: 1, expires_at: 1.day.from_now)
    end
    let(:run) do
      node = TranscodeNode.create!(name: "Mini", token_digest: SecureRandom.hex, token_prefix: "ab")
      TranscodeRun.create!(id: download.id, transcode_node: node, playback_session: session)
    end

    it "keeps each token to its own surface" do
      download_token = Playback::DownloadToken.issue(download)
      run_token = Playback::RunToken.issue(run)
      expect(run.id).to eq(download.id)

      expect(Playback::DownloadToken.verify(download_token)).to eq(download)
      expect(Playback::RunToken.verify(run_token)).to eq(run)
      expect(Playback::RunToken.verify(download_token)).to be_nil
      expect(Playback::DownloadToken.verify(run_token)).to be_nil
      expect(described_class.verify(download_token)).to be_nil
      expect(described_class.verify(run_token)).to be_nil
      stream_token = described_class.issue(session)
      expect(Playback::DownloadToken.verify(stream_token)).to be_nil
      expect(Playback::RunToken.verify(stream_token)).to be_nil
    end

    it "rotates all three with STREAM_TOKEN_KEY" do
      tokens = [ Playback::DownloadToken.issue(download), Playback::RunToken.issue(run) ]
      stub_const("ENV", ENV.to_h.merge("STREAM_TOKEN_KEY" => "rotated"))

      expect(Playback::DownloadToken.verify(tokens.first)).to be_nil
      expect(Playback::RunToken.verify(tokens.last)).to be_nil
    end
  end
end

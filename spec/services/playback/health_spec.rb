# typed: false
# frozen_string_literal: true

require "rails_helper"

# The Playback page's health strip: a verdict per check, at its edges.
RSpec.describe Playback::Health do
  let(:household) { Household.create!(name: "Stream") }
  let(:library) { create_library(household: household, roots: build_root) }
  let(:profile) { Profile.default_for(household) }
  let(:movie) { Movie.create!(household: household, library: library, title: "Heat", year: 1995) }

  def media_file
    MediaFile.create!(household: household, library: library, path: "/m/#{SecureRandom.hex(3)}.mkv", size: 1, mtime: Time.current,
      state: "probed", duration_seconds: 60)
  end

  def play(method = "direct", file: media_file, decision: {}, started_at: 1.hour.ago, **attributes)
    PlaybackSession.create!(household: household, profile: profile, playable: movie, media_file: file, method: method,
      decision: decision, started_at: started_at, last_seen_at: started_at, **attributes)
  end

  def check(key) = described_class.checks.find { |each| each.key.serialize == key }

  describe "failed plays" do
    it "is fine with nothing wrong, and says so" do
      expect(check("failed_plays")).to have_attributes(status: described_class::Status::Ok, detail: "Nothing was played this week.")
      play
      expect(check("failed_plays").detail).to eq("None of this week's 1 play ended on an error.")
    end

    it "wants something done about any failed conversion or player error, and links to them" do
      play("video_transcode", transcode_error: "ffmpeg exited 1")
      PlaybackEvent.create!(playback_session: play, kind: "error")
      play("direct", started_at: 8.days.ago, transcode_error: "long ago")
      result = check("failed_plays")
      expect(result).to have_attributes(status: described_class::Status::Act, metric: "100.0%",
        detail: "This week 1 conversion failed and 1 player reported an error (the aim is under 1%).")
      expect(result.link).to include(tab: "sessions", outcomes: %w[failed errored])
    end

    it "is worth a look when more than one play in twenty stalls" do
      19.times { play }
      PlaybackEvent.create!(playback_session: play, kind: "stall")
      expect(check("failed_plays").status).to eq(described_class::Status::Ok)
      PlaybackEvent.create!(playback_session: play, kind: "stall")
      expect(check("failed_plays")).to have_attributes(status: described_class::Status::Watch, metric: "0.0%")
      expect(check("failed_plays").link).to include(outcomes: %w[stalled])
    end

    # A session that failed and carried on
    # a rung down didn't end the play.
    it "counts a play that fell back and carried on as recovered, not failed" do
      failed = play("remux")
      PlaybackEvent.create!(playback_session: failed, kind: "error")
      play("video_transcode", fallback_from_id: failed.id)
      98.times { play }
      result = check("failed_plays")
      expect(result).to have_attributes(status: described_class::Status::Ok, metric: "0.0%",
        detail: "None of this week's 99 plays ended on an error. 1 play that failed carried on another way.")
    end
  end

  describe "live conversions" do
    it "counts the ones an optimized version would have spared, against last week" do
      play("video_transcode")
      play("video_transcode", decision: { "video" => { "tonemap" => true } })
      ready = media_file
      OptimizedVersion.create!(household: household, media_file: ready, state: "ready", size: 1)
      play("video_transcode", file: ready)
      play("video_transcode", started_at: 10.days.ago)
      result = check("live_conversions")
      expect(result).to have_attributes(status: described_class::Status::Watch, metric: "3",
        detail: "3 plays converted video live this week (1 last week); 1 could have played an optimized version.")
      expect(result.link).to include(tab: "converting", sort: "conversions")
    end

    it "is fine when nothing could have been spared" do
      play("video_transcode", decision: { "video" => { "tonemap" => true } })
      expect(check("live_conversions").status).to eq(described_class::Status::Ok)
    end
  end

  describe "start-up speed" do
    def timed(method, ms, times)
      times.times { PlaybackEvent.create!(playback_session: play(method), kind: "startup", detail: { "ms" => ms }) }
    end

    it "is worth a look when nineteen in twenty take longer than the target, given enough plays" do
      timed("direct", 300, 10)
      timed("remux", 2400, 4)
      expect(check("startup")).to have_attributes(status: described_class::Status::Ok, metric: "300 ms")
      timed("remux", 2400, 1)
      expect(check("startup")).to have_attributes(status: described_class::Status::Watch,
        detail: "For nineteen plays in twenty, repackaging takes up to 2.4 s (aiming for 1.5 s).")
    end
  end

  describe "the optimize backlog" do
    def queue(**attributes) = OptimizedVersion.create!(household: household, media_file: media_file, **attributes)

    it "wants the transcoder started when something is waiting and nothing will encode it" do
      expect(check("optimizer").status).to eq(described_class::Status::Ok)
      queue
      expect(check("optimizer")).to have_attributes(status: described_class::Status::Act, action: "Start the transcoder.")
    end

    it "wants failures looked at, and a full budget freed up" do
      Playback::TranscoderHeartbeat.beat!(encoder: Playback::Encoders::Kind::Software, busy: false)
      queue(state: "failed")
      expect(check("optimizer")).to have_attributes(status: described_class::Status::Act, link: { tab: "optimized", states: %w[failed] })

      OptimizedVersion.delete_all
      AppSetting.current.update!(optimize_budget_gb: 10)
      AppSetting.bust_cache!
      queue(state: "ready", size: 9.5.gigabytes)
      expect(check("optimizer")).to have_attributes(status: described_class::Status::Watch)
      expect(check("optimizer").link).to include(tab: "optimized", unplayed_days: 90)
    end

    it "notices a queue that hasn't moved in a week" do
      Playback::TranscoderHeartbeat.beat!(encoder: Playback::Encoders::Kind::Software, busy: false)
      queue(created_at: 9.days.ago)
      expect(check("optimizer")).to have_attributes(status: described_class::Status::Watch, metric: "1")
      queue(state: "ready", size: 1, finished_at: 1.day.ago)
      expect(check("optimizer").status).to eq(described_class::Status::Ok)
    end
  end
end

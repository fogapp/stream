# typed: false
# frozen_string_literal: true

require "rails_helper"

# Silent failure is the enemy (CLAUDE.md invariant 5): what each job does
# when its work fails — where it says so, whether it tries again, and when
# it gives up without a dead letter because the failure is already recorded
# somewhere better.
RSpec.describe "Job failure paths" do
  include RequestHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:household) { create_household }

  def dead_letters = ActivityEntry.where(event: "job.dead")

  def retry_later(job_class)
    job = enqueued_jobs.find { |queued| queued["job_class"] == job_class.name }
    job && ActiveJob::Base.deserialize(job).tap { enqueued_jobs.delete(job) }
  end

  describe ScanLibraryJob do
    it "records an unreadable root on the library and the timeline, counts it, and doesn't retry" do
      root = build_root("a.mp4" => "h264_aac.mp4")
      library = create_library(household: household, roots: root, name: "Films")
      FileUtils.rm_rf(root) # a share that went away

      2.times { described_class.perform_now(library.id) }

      expect(library.reload).to have_attributes(consecutive_scan_failures: 2, last_scan_error: be_present, last_scanned_at: nil, scanning?: false)
      expect(ActivityEntry.where(event: "library.scan_failed").pluck(:summary)).to all(start_with("Films: "))
      expect(enqueued_jobs.map { |job| job["job_class"] }).not_to include("ScanLibraryJob")
      expect(dead_letters).to be_empty # the library says so already
    end

    it "leaves the library's own record to full scans: one folder's scan says nothing of the rest" do
      root = build_root("Heat/a.mp4" => "h264_aac.mp4")
      library = create_library(household: household, roots: root, name: "Films")
      library.update!(last_scan_error: "The share is gone", consecutive_scan_failures: 3, last_scanned_at: nil)

      described_class.perform_now(library.id, File.join(root, "Heat"))

      expect(library.reload).to have_attributes(last_scan_error: "The share is gone", consecutive_scan_failures: 3, last_scanned_at: nil,
        last_scan_started_at: nil, scanning?: false)
    end

    it "says on the library when a folder couldn't be read, without calling that a good scan" do
      root = build_root("Heat/a.mp4" => "h264_aac.mp4", "Alien/b.mp4" => "h264_aac.mp4")
      library = create_library(household: household, roots: root, name: "Films")
      described_class.perform_now(library.id)
      scanned_at = library.reload.last_scanned_at
      allow(Dir).to receive(:children).and_call_original
      allow(Dir).to receive(:children).with(File.join(root, "Heat")).and_raise(Errno::EIO)

      described_class.perform_now(library.id)

      expect(library.reload).to have_attributes(last_scanned_at: scanned_at, consecutive_scan_failures: 1, last_scan_error: /Heat/, scanning?: false)
      expect(ActivityEntry.where(event: "library.scan_incomplete").sole).to have_attributes(severity: "warn")
      expect(MediaFile.where(library: library).pluck(:state).uniq).not_to include("missing")
      expect(dead_letters).to be_empty
    end

    it "clears the failure once a scan works again, and says what it found" do
      root = build_root("a.mp4" => "h264_aac.mp4")
      library = create_library(household: household, roots: root, name: "Films")
      library.update!(last_scan_error: "gone", consecutive_scan_failures: 3)

      described_class.perform_now(library.id)

      expect(library.reload).to have_attributes(last_scan_error: nil, consecutive_scan_failures: 0, last_scanned_at: be_present)
      expect(ActivityEntry.find_by(event: "library.scanned").summary).to eq("Films: 1 new")
    end
  end

  describe MatchMediaFileJob do
    let(:library) { create_library(household: household, roots: build_root, name: "Films") }

    def file(state: "probed")
      MediaFile.create!(household: household, library: library, path: "/m/Heat (1995)/Heat.mkv", size: 1, mtime: Time.current, state: state)
    end

    it "matches only a probed file" do
      allow(Catalog::FileMatcher).to receive(:new).and_call_original

      described_class.perform_now(file(state: "discovered").id)
      described_class.perform_now(SecureRandom.uuid)

      expect(Catalog::FileMatcher).not_to have_received(:new)
    end

    it "gives up on a file it can't place without a dead letter, since the file's page says so" do
      probed = file
      allow(Catalog::FileMatcher).to receive(:new).and_return(
        instance_double(Catalog::FileMatcher).tap { |matcher| allow(matcher).to receive(:call).and_raise(Catalog::FileMatcher::Unplaceable, "no idea") }
      )

      described_class.perform_now(probed.id, library.id)

      expect(enqueued_jobs).to be_empty
      expect(dead_letters).to be_empty
    end

    it "waits out TMDB rate limits a minute at a time" do
      probed = file
      freeze_time
      allow(Catalog::FileMatcher).to receive(:new).and_return(
        instance_double(Catalog::FileMatcher).tap do |matcher|
          allow(matcher).to receive(:call).and_raise(UpstreamHttpClient::RateLimitError.new("TMDB rate limited this request", status: 429))
        end
      )

      described_class.perform_now(probed.id, library.id)

      retry_job = enqueued_jobs.sole
      expect(Time.zone.parse(retry_job["scheduled_at"]) - Time.current).to be_between(60, 70)
    end

    it "keys its concurrency on the file's library" do
      probed = file
      expect(described_class.new(probed.id, library.id).concurrency_key).to include("match_library:#{library.id}")
    end
  end

  describe TranscribeWithWhisperJob do
    it "records a Whisper failure on the file's analysis, retries later, and succeeds on the next try" do
      require_ffprobe!
      root = build_root("TC/Silent.mp4" => "h264_aac.mp4")
      library = create_library(household: household, roots: root, kind: "channels", name: "YouTube")
      source = File.join(root, "TC/Silent.mp4")
      media = MediaFile.create!(household: household, library: library, path: source, size: File.size(source), mtime: Time.current,
        state: "discovered")
      Media::FileProber.new(media).call
      WhisperSetting.create!(household: household, url: "http://whisper.lan:9000")
      asr = "http://whisper.lan:9000/asr?encode=true&output=json&task=transcribe"
      stub_request(:post, asr).to_return(status: 503, body: "model loading").then
        .to_return(status: 200, body: { language: "en", segments: [ { start: 0.5, end: 1.5, text: " Hello." } ] }.to_json,
          headers: { "Content-Type" => "application/json" })

      described_class.perform_now(media.id)

      run = media.analysis_runs.find_by(step: "transcript")
      expect(run).to have_attributes(status: "failed", consecutive_failures: 1, error: a_string_including("503"))
      later = retry_later(described_class)
      expect(later).to be_present

      later.perform_now
      expect(run.reload).to have_attributes(status: "succeeded", consecutive_failures: 0, error: nil)
      expect(media.reload.transcript).to have_attributes(source: "whisper", line_count: 1)
    end

    it "does nothing while Whisper is switched off" do
      library = create_library(household: household, roots: build_root, kind: "channels", name: "YouTube")
      media = MediaFile.create!(household: household, library: library, path: "/tc/a.mp4", size: 1, mtime: Time.current, state: "probed")
      WhisperSetting.create!(household: household, url: "http://whisper.lan:9000", enabled: false)

      described_class.perform_now(media.id)

      expect(media.analysis_runs).to be_empty
      expect(WebMock).not_to have_requested(:any, /whisper/)
    end
  end

  describe DetectMarkersJob do
    it "stands down quietly where ffmpeg can't fingerprint audio" do
      show = Show.create!(household: household, library: create_library(household: household, roots: build_root, kind: "shows"),
        folder: "Office", title: "The Office")
      allow(Markers::Detector).to receive(:detect_season).and_raise(Markers::Fingerprinter::Unavailable, "no chromaprint")

      described_class.perform_now(show.id, 1)

      expect(enqueued_jobs).to be_empty
      expect(dead_letters).to be_empty
    end

    it "tries a read that failed once more, an hour later" do
      show = Show.create!(household: household, library: create_library(household: household, roots: build_root, kind: "shows"),
        folder: "Office", title: "The Office")
      allow(Markers::Detector).to receive(:detect_season).and_raise(Markers::Fingerprinter::ReadFailed, "Input/output error")

      described_class.perform_now(show.id, 1)

      expect(enqueued_jobs.last).to include("job_class" => "DetectMarkersJob")
      expect(Time.zone.parse(enqueued_jobs.last["scheduled_at"])).to be_between(55.minutes.from_now, 90.minutes.from_now)
    end
  end

  describe ScheduleStationJob do
    it "says on the timeline when a channel has nothing to air" do
      station = Station.create!(household: household, number: "4", name: "Empty")
      station.station_blocks.create!(layer: "base", source: { show_ids: [ SecureRandom.uuid ] }, ordering: "shuffle")

      described_class.perform_now(station.id)

      expect(station.reload.last_error).to be_present
      entry = ActivityEntry.find_by(event: "station.unfilled")
      expect(entry).to have_attributes(severity: "warn", household_id: household.id)
      expect(entry.summary).to start_with("Channel 4 Empty: ")
    end
  end

  describe UpdateYtDlpJob do
    it "notes a failed update as a warning rather than dying" do
      allow(Youtube::YtDlp).to receive_messages(version: "2026.01.01")
      allow(Youtube::YtDlp).to receive(:update!).and_raise(Youtube::YtDlp::Error, "GitHub said no")

      described_class.perform_now

      expect(ActivityEntry.find_by(event: "yt_dlp.update_failed")).to have_attributes(severity: "warn",
        summary: "Couldn't update yt-dlp: GitHub said no")
      expect(dead_letters).to be_empty
    end

    it "says what it updated to, and nothing when it was already current" do
      allow(Youtube::YtDlp).to receive_messages(version: "2026.01.01", update!: "2026.02.01")
      described_class.perform_now
      expect(ActivityEntry.find_by(event: "yt_dlp.updated").summary).to eq("yt-dlp updated from 2026.01.01 to 2026.02.01")

      allow(Youtube::YtDlp).to receive_messages(update!: "2026.01.01")
      described_class.perform_now
      expect(ActivityEntry.where(event: "yt_dlp.updated").count).to eq(1)
    end
  end

  describe ProduceBackupJob do
    after { FileUtils.rm_rf(FogBackup::Staging.root) }

    it "says a backup failed on its run, where fog's status check reads it, and doesn't try again" do
      run = JobRun.create!(job_key: ProduceBackupJob::JOB_KEY, trigger: "system")
      allow(ToolRunner).to receive(:run).and_return(ToolRunner::Result.new(status: 1, stdout: "", stderr: "pg_dump: connection refused"))

      expect { described_class.perform_now(run.id) }.to raise_error(FogBackup::Producer::Error, /pg_dump/)

      expect(run.reload).to have_attributes(status: "failed", error: a_string_including("pg_dump"))
      expect(enqueued_jobs).to be_empty
      expect(dead_letters.sole.summary).to include("ProduceBackupJob permanently failed")
    end
  end
end

# typed: false
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Markers" do
  step = Markers::Matcher::SECONDS_PER_POINT

  describe Markers::Matcher do
    let(:random) { Random.new(7) }

    def noise(count) = Array.new(count) { random.rand(2**32) - (2**31) }

    # The same sound heard twice isn't bit-identical: flip a bit in about a
    # third of the points (identical audio still fingerprints identically
    # most of the time, which is what the index anchors on).
    def smudge(points) = points.map { |point| random.rand < 0.33 ? point ^ (1 << random.rand(32)) : point }

    it "finds a shared theme at different offsets in each episode" do
      theme = noise(250) # ~31 s
      a = noise(100) + theme + noise(300)
      b = noise(40) + smudge(theme) + noise(500)

      match = described_class.best(a, b)

      expect(match.a.start).to be_within(step).of(100 * step)
      expect(match.b.start).to be_within(step).of(40 * step)
      expect(match.a.duration).to be_within(2 * step).of(250 * step)
      expect(match.confidence).to be > 0.95
    end

    it "bridges a short burst of different sound inside the theme" do
      theme = noise(300)
      broken = theme.dup
      broken[150, 10] = noise(10) # ~1.2 s of a door slam
      match = described_class.best(noise(50) + theme + noise(50), noise(80) + broken + noise(50))
      expect(match.a.duration).to be_within(2 * step).of(300 * step)
    end

    it "finds nothing between unrelated episodes, or when the shared part is too short" do
      expect(described_class.best(noise(800), noise(800))).to be_nil
      jingle = noise(60) # ~7 s: a logo sting, not an intro
      expect(described_class.best(noise(100) + jingle + noise(100), noise(30) + jingle + noise(200))).to be_nil
    end
  end

  describe Marker do
    let(:household) { Household.create!(name: "M") }
    let(:file) do
      MediaFile.create!(household: household, library: create_library(household: household, roots: build_root), path: "/x.mkv",
        size: 1, mtime: Time.current, state: "probed", duration_seconds: 1800,
        chapters: [ { "start" => 0.0, "end" => 62.0, "title" => "Opening" }, { "start" => 62.0, "end" => 1700.0, "title" => "Episode" },
                    { "start" => 1700.0, "end" => 1800.0, "title" => "End Credits" } ])
    end

    it "reads intro and credits from chapter names" do
      Markers::Detector.from_chapters(file)
      expect(file.markers.order(:start_seconds).map { |m| [ m.kind, m.start_seconds, m.end_seconds, m.source ] })
        .to eq([ [ "intro", 0.0, 62.0, "chapter" ], [ "credits", 1700.0, 1800.0, "chapter" ] ])
    end

    it "never lets audio matching overwrite a chapter, or anything overwrite a person's correction" do
      Markers::Detector.from_chapters(file)
      described_class.offer(file, Marker::Kind::Intro, start: 5.0, finish: 50.0, source: Marker::Source::Detected)
      expect(file.markers.find_by(kind: "intro").source).to eq("chapter")

      described_class.offer(file, Marker::Kind::Intro, start: 1.0, finish: 60.0, source: Marker::Source::Manual)
      described_class.offer(file, Marker::Kind::Intro, start: 0.0, finish: 62.0, source: Marker::Source::Chapter)
      expect(file.markers.find_by(kind: "intro")).to have_attributes(source: "manual", start_seconds: 1.0)
    end
  end

  describe Markers::Fingerprinter do
    let(:household) { Household.create!(name: "Print") }

    # A file the share wouldn't read isn't a server without chromaprint: the
    # one stands the job down for good, the other is that file's failure.
    it "tells a read that failed from a tool that isn't there" do
      library = create_library(household: household, roots: build_root, kind: "shows")
      file = MediaFile.create!(household: household, library: library, path: "/s/e1.mkv", size: 1, mtime: Time.current,
        state: "probed", duration_seconds: 1800)
      file.media_streams.create!(index: 1, kind: "audio", codec: "aac")
      allow(described_class).to receive(:available?).and_return(true)
      allow(ToolRunner).to receive(:run_advancing).and_return(instance_double(ToolRunner::Result, success?: false, stderr: "Input/output error\n"))

      expect { described_class.for(file, AudioFingerprint::Segment::Whole) }.to raise_error(described_class::ReadFailed, /Input\/output error/)
    end

    # A read on the heavy queue shares the NAS with whoever is watching: it
    # stands still while they do, and only a read that stops is given up on.
    it "reads under the heavy queue's hold, timed by whether the read advances" do
      library = create_library(household: household, roots: build_root, kind: "shows")
      file = MediaFile.create!(household: household, library: library, path: "/s/e1.mkv", size: 1, mtime: Time.current,
        state: "probed", duration_seconds: 1800)
      file.media_streams.create!(index: 1, kind: "audio", codec: "aac")
      hold = -> { false }
      allow(described_class).to receive(:available?).and_return(true)
      allow(ToolRunner).to receive(:run_advancing) do |argv, **|
        File.binwrite(argv.last, [ 1, 2, 3 ].pack("l<*"))
        ToolRunner::Result.new(status: 0, stdout: "", stderr: "")
      end

      print = described_class.for(file, AudioFingerprint::Segment::Head, hold: hold)

      expect(print.points).to eq([ 1, 2, 3 ])
      expect(ToolRunner).to have_received(:run_advancing)
        .with(array_including("-progress", "pipe:1"), stall_timeout: described_class::STALL_TIMEOUT, hold: hold)
    end

    # Two jobs for one season (each filed episode asks) can read the same
    # file at once; the one that finishes second keeps the first's print.
    it "keeps the print another read stored while this one ran" do
      library = create_library(household: household, roots: build_root, kind: "shows")
      file = MediaFile.create!(household: household, library: library, path: "/s/e1.mkv", size: 1, mtime: Time.current,
        state: "probed", duration_seconds: 1800)
      file.media_streams.create!(index: 1, kind: "audio", codec: "aac")
      allow(described_class).to receive(:available?).and_return(true)
      allow(ToolRunner).to receive(:run_advancing) do |argv, **|
        AudioFingerprint.create!(media_file: file, segment: "head", offset_seconds: 0, points: [ 7 ])
        File.binwrite(argv.last, [ 1, 2, 3 ].pack("l<*"))
        ToolRunner::Result.new(status: 0, stdout: "", stderr: "")
      end

      print = described_class.for(file, AudioFingerprint::Segment::Head)

      expect(print.points).to eq([ 7 ])
      expect(AudioFingerprint.where(media_file: file).count).to eq(1)
    end
  end

  # Every episode filed asks for its season to be compared, so a season of
  # twenty asks twenty times. Fingerprints are already made here, so this
  # needs no ffmpeg.
  describe "a season asked for again" do
    let(:household) { Household.create!(name: "Again") }
    let(:library) { create_library(household: household, roots: build_root, kind: "shows") }
    let(:show) { Show.create!(household: household, library: library, folder: "Show", title: "Show") }
    let(:season) { show.seasons.create!(season_number: 1) }
    let(:random) { Random.new(11) }

    def episode(number)
      file = MediaFile.create!(household: household, library: library, path: "/s/e#{number}.mkv", size: number, mtime: Time.current,
        state: "probed", duration_seconds: 1800)
      AudioFingerprint::Segment.values.each do |segment|
        AudioFingerprint.create!(media_file: file, segment: segment.serialize, offset_seconds: 0, points: Array.new(400) { random.rand(2**32) - (2**31) })
      end
      show.episodes.create!(season: season, season_number: 1, episode_number: number).editions.create!(media_file: file)
      file
    end

    # The whole-episode read is the biggest of a season's. A green run over
    # one that failed is the silent failure AnalysisRun exists to end.
    it "records a recap's read that failed on the episode, rather than a success" do
      files = (1..2).map { |number| episode(number) }
      AudioFingerprint.where(segment: "whole").delete_all
      allow(Markers::Fingerprinter).to receive(:for).and_raise(Markers::Fingerprinter::ReadFailed, "Input/output error")

      expect { Markers::Detector.detect_season(show, 1) }.to raise_error(Markers::Fingerprinter::ReadFailed)

      expect(AnalysisRun.find_by(media_file: files.first, step: "markers").status).to eq("succeeded")
      expect(AnalysisRun.find_by(media_file: files.last, step: "markers")).to have_attributes(status: "failed", error: /Input\/output error/)
    end

    # Each of a season's episodes asks as it's filed: one comparison answers
    # all the ones that arrive before it starts.
    it "queues a season's comparison once for the episodes that arrive together" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

      3.times { Markers::Detector.detect_later(show, 1, priority: 5) }

      queued = enqueued_jobs.select { |job| job["job_class"] == "DetectMarkersJob" }
      expect(queued.size).to eq(1)
      expect(queued.first).to include("arguments" => [ show.id, 1 ], "priority" => 5)
      expect(Time.zone.parse(queued.first["scheduled_at"])).to be_within(1.minute).of(5.minutes.from_now)
    end

    it "reads each fingerprint once, then leaves the season alone until a file arrives or someone asks" do
      allow(Markers::Fingerprinter).to receive(:for).and_call_original
      files = (1..3).map { |number| episode(number) }

      Markers::Detector.detect_season(show, 1)
      # The openings and endings come in one query; the two whole episodes a
      # later one looks back at are asked for one by one.
      expect(Markers::Fingerprinter).to have_received(:for).exactly(2).times
      expect(AnalysisRun.where(step: "markers", status: "succeeded").count).to eq(3)

      expect { Markers::Detector.detect_season(show, 1) }.not_to(change { AnalysisRun.order(:id).pluck(:updated_at) })
      expect(Markers::Fingerprinter).to have_received(:for).exactly(2).times

      episode(4)
      Markers::Detector.detect_season(show, 1)
      expect(AnalysisRun.where(step: "markers", status: "succeeded").count).to eq(4)
      expect(Markers::Fingerprinter).to have_received(:for).exactly(2 + 3).times

      Markers::Detector.forget_season(show.id, 1)
      expect { Markers::Detector.detect_season(show, 1) }.to(change { AnalysisRun.find_by(media_file: files.first, step: "markers").updated_at })
    end
  end

  describe Markers::Detector do
    before do
      require_ffprobe!
      skip "this ffmpeg can't fingerprint (no chromaprint muxer); CI and the production image can" unless Markers::Fingerprinter.available?
    end

    let(:household) { Household.create!(name: "Season") }

    # An episode: its own cold open, the show's theme (30 s), its own story,
    # the show's credits music (30 s). Melodies rather than noise or steady
    # tones: Chromaprint hears pitch, and every white noise — or every
    # steady tone — sounds alike to it.
    # A melody: a new note every half second, its pitch a hash of the note
    # number and a seed (the fract(sin(x) * 43758.5453) hash).
    def melody(seed, seconds)
      hash = "(sin(floor(t*2)*12.9898+#{seed}*78.233)*43758.5453)"
      "aevalsrc='0.5*sin(2*PI*(220+660*(#{hash}-floor(#{hash})))*t)':d=#{seconds}"
    end

    def episode(dir, number)
      path = File.join(dir, "Show/Season 1/Show S01E0#{number}.mkv")
      FileUtils.mkdir_p(File.dirname(path))
      audio = "#{melody(number, 10 + (number * 3))}[a];#{melody(1000, 30)}[b];#{melody(number + 50, 40)}[c];" \
              "#{melody(2000, 30)}[d];[a][b][c][d]concat=n=4:v=0:a=1"
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i color=c=black:s=64x36:r=5 -filter_complex #{audio} -shortest
        -c:v libx264 -preset ultrafast -c:a aac #{path}])
      path
    end

    it "finds each episode's intro and credits by comparing it with its neighbour" do
      # The episodes are the library as it was found: made before it, so
      # the root is held fixed (media invariant 1) from there on.
      root = build_root
      paths = (1..3).to_h { |number| [ number, episode(root, number) ] }
      library = create_library(household: household, roots: root, kind: "shows")
      show = Show.create!(household: household, library: library, folder: "Show", title: "Show")
      season = show.seasons.create!(season_number: 1)
      paths.each do |number, path|
        file = MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: Time.current,
          state: "discovered")
        Media::FileProber.new(file).call
        show.episodes.create!(season: season, season_number: 1, episode_number: number).editions.create!(media_file: file.reload)
      end

      expect(described_class.detect_season(show, 1)).to eq(6)

      show.episodes.each do |ep|
        file = ep.media_files.first
        cold_open = 10 + (ep.episode_number * 3)
        intro = file.markers.find_by(kind: "intro")
        expect(intro.start_seconds).to be_within(1.5).of(cold_open)
        expect(intro.end_seconds - intro.start_seconds).to be_within(2).of(30)
        credits = file.markers.find_by(kind: "credits")
        expect(credits.start_seconds).to be_within(1.5).of(cold_open + 70)
        expect(credits.source).to eq("detected")
      end
    end

    # Episode 2 opens with a recap: 8 s from each of episode 1's three
    # story scenes (the same audio), then the theme.
    def recap_episode(dir, number, parts)
      path = File.join(dir, "Show/Season 1/Show S01E0#{number}.mkv")
      FileUtils.mkdir_p(File.dirname(path))
      labels = parts.each_index.map { |i| "[p#{i}]" }
      audio = parts.each_with_index.map { |(seed, seconds), i| "#{melody(seed, seconds)}#{labels[i]}" }.join(";") +
              ";#{labels.join}concat=n=#{parts.size}:v=0:a=1"
      ToolRunner.run(%W[ffmpeg -v error -y -f lavfi -i color=c=black:s=64x36:r=5 -filter_complex #{audio} -shortest
        -c:v libx264 -preset ultrafast -c:a aac #{path}])
      path
    end

    it "finds a recap made of clips from the episode before" do
      root = build_root
      layouts = {
        1 => [ [ 1, 13 ], [ 1000, 30 ], [ 101, 15 ], [ 102, 15 ], [ 103, 15 ], [ 2000, 30 ] ],
        2 => [ [ 101, 8 ], [ 102, 8 ], [ 103, 8 ], [ 1000, 30 ], [ 201, 40 ], [ 2000, 30 ] ]
      }
      paths = layouts.to_h { |number, parts| [ number, recap_episode(root, number, parts) ] }
      library = create_library(household: household, roots: root, kind: "shows")
      show = Show.create!(household: household, library: library, folder: "Show", title: "Show")
      season = show.seasons.create!(season_number: 1)
      paths.each do |number, path|
        file = MediaFile.create!(household: household, library: library, path: path, size: File.size(path), mtime: Time.current,
          state: "discovered")
        Media::FileProber.new(file).call
        show.episodes.create!(season: season, season_number: 1, episode_number: number).editions.create!(media_file: file.reload)
      end

      described_class.detect_season(show, 1)

      second = show.episodes.find_by(episode_number: 2).media_files.first
      recap = second.markers.find_by(kind: "recap")
      expect(recap).to have_attributes(start_seconds: 0.0, source: "detected")
      # The recap runs up to the intro, whose found edge can be a second or
      # two early where the two are back to back.
      intro = second.markers.find_by(kind: "intro")
      expect(intro.start_seconds).to be_within(2).of(24)
      expect(recap.end_seconds).to eq(intro.start_seconds)
      # The first episode has nothing before it to recap.
      expect(show.episodes.find_by(episode_number: 1).media_files.first.markers.find_by(kind: "recap")).to be_nil
    end
  end
end

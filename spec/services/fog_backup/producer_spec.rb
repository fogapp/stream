# typed: false
# frozen_string_literal: true

require "rails_helper"

# Real pg_dump + real tar: the artifact this produces is the artifact fog
# downloads, so the round trip through Preflight is the contract's own test.
RSpec.describe FogBackup::Producer do
  after { FileUtils.rm_rf(FogBackup::Staging.root) }

  it "produces a verifiable artifact that passes preflight" do
    run = JobRun.create!(job_key: "produce_backup", trigger: "system")

    message = described_class.new(job_run: run).call

    expect(message).to include("artifact")

    path = FogBackup::Staging.artifact_path(run.id)
    info = FogBackup::Staging.artifact_info(run.id)
    expect(path).to exist
    # The producer's claim must be independently verifiable — it's what fog
    # checks the download against.
    expect(path.size).to eq(info["bytes"])
    expect(Digest::SHA256.file(path.to_s).hexdigest).to eq(info["sha256"])
    # And remembered after fog collects and deletes it: the descriptor's estimate.
    expect(FogBackup::Staging.last_artifact_bytes).to eq(info["bytes"])

    result = FogBackup::Preflight.check(artifact_path: path)
    expect(result.errors).to eq([])
    expect(result.manifest.app).to eq("stream")
    expect(result.manifest.schema_version).to eq(FogBackup::Manifest.code_schema_version)
    expect(result.manifest.components.map { |c| c["name"] }).to contain_exactly("primary", "storage")
  end

  # fog-backup/2: nothing compressed whole, so fog's deduplicating store can
  # share chunks with the night before.
  it "writes fog-backup/2: an uncompressed dump and a plain storage tar" do
    run = JobRun.create!(job_key: "produce_backup", trigger: "system")
    allow(ToolRunner).to receive(:run).and_call_original

    described_class.new(job_run: run).call

    expect(ToolRunner).to have_received(:run)
      .with(array_including("pg_dump", "-Fc", "-Z0", "--no-owner", "--no-privileges", "--no-comments"), any_args)
    expect(ToolRunner).not_to have_received(:run).with(array_including("--zstd"), any_args)

    result = FogBackup::Preflight.check(artifact_path: FogBackup::Staging.artifact_path(run.id))
    expect(result.errors).to eq([])
    expect(result.manifest.format).to eq("fog-backup/2")
    expect(result.manifest.components.to_h { |c| [ c["name"], c["path"] ] })
      .to eq("primary" => "db/primary.dump", "storage" => "files/storage.tar")

    Dir.mktmpdir do |dir|
      ToolRunner.run([ "tar", "-xf", FogBackup::Staging.artifact_path(run.id).to_s, "-C", dir ], timeout: 60)
      expect(File).not_to exist(File.join(dir, "files/storage.tar.zst"))
      # A plain tar: the ustar magic at offset 257, no zstd frame.
      expect(File.binread(File.join(dir, "files/storage.tar"), 5, 257)).to eq("ustar")
      # pg_restore still reads the dump, and it says it isn't compressed.
      toc = ToolRunner.run([ "pg_restore", "-l", File.join(dir, "db/primary.dump") ], timeout: 60)
      expect(toc.status).to eq(0)
      expect(toc.stdout).to match(/Compression: (none|0)$/)
    end
  end

  # Trailer videos and the fetched yt-dlp can be fetched again, and
  # thumbnails, image subtitles and embedded fonts made again from the file;
  # keeping them made the pre-update backup crawl through gigabytes of them.
  it "leaves re-fetchable and re-renderable files out of the storage archive" do
    storage = Rails.root.join("storage")
    id = SecureRandom.uuid
    made = [ storage, *%w[artwork trailers tools trickplay subtitles].map { |dir| storage.join(dir) } ].reject(&:exist?)
    kept = %W[artwork/keep.webp subtitles/#{id}/e3.vtt subtitles/#{id}/e4.ass subtitles/#{id}/downloaded/en.1.srt]
    dropped = %W[trailers/drop.mp4 tools/yt-dlp/drop trickplay/#{id}/1/sheet-0.webp subtitles/#{id}/e5.sup
      subtitles/#{id}/fonts/Drop.ttf]
    (kept + dropped).each do |file|
      storage.join(file).dirname.mkpath
      storage.join(file).write("x")
    end
    run = JobRun.create!(job_key: "produce_backup", trigger: "system")

    described_class.new(job_run: run).call

    Dir.mktmpdir do |dir|
      ToolRunner.run([ "tar", "-xf", FogBackup::Staging.artifact_path(run.id).to_s, "-C", dir ], timeout: 60)
      # Streamed and filtered rather than read whole: a developer's own
      # storage tree can list past ToolRunner's output cap.
      listing = IO.popen([ "tar", "-tf", File.join(dir, "files/storage.tar") ]) do |out|
        out.each_line.map(&:strip).grep(%r{\Astorage/(artwork/keep|trailers|tools|fog|trickplay/#{id}|subtitles/#{id})})
          .reject { |entry| entry.end_with?("/") }
      end
      expect(listing).to match_array(kept.map { |file| "storage/#{file}" })
    end
  ensure
    made&.each { |dir| FileUtils.rm_rf(dir) }
    %w[trickplay subtitles].each { |dir| FileUtils.rm_rf(storage.join(dir, id)) } if id
  end

  # The worker writes storage/ while the backup reads it; GNU tar exits 1
  # ("file changed as we read it") with a complete archive. That must not
  # fail the backup — and with it, the deploy fog gates on it.
  it "accepts tar's file-changed warning on the storage archive" do
    run = JobRun.create!(job_key: "produce_backup", trigger: "system")
    real_run = ToolRunner.method(:run)
    allow(ToolRunner).to receive(:run) do |argv, **opts|
      result = real_run.call(argv, **opts)
      next result unless argv.first == "tar" && argv.include?("--exclude") # the storage archive

      ToolRunner::Result.new(status: 1, stdout: result.stdout, stderr: "tar: storage/trickplay: file changed as we read it")
    end

    expect { described_class.new(job_run: run).call }.not_to raise_error
    expect(FogBackup::Preflight.check(artifact_path: FogBackup::Staging.artifact_path(run.id)).errors).to eq([])
  end

  it "still fails on tar's fatal exit" do
    run = JobRun.create!(job_key: "produce_backup", trigger: "system")
    allow(ToolRunner).to receive(:run).and_call_original
    allow(ToolRunner).to receive(:run).with(array_including("tar", "--exclude"), any_args)
      .and_return(ToolRunner::Result.new(status: 2, stdout: "", stderr: "tar: Error is not recoverable"))

    expect { described_class.new(job_run: run).call }.to raise_error(FogBackup::Producer::Error, /tar exited 2/)
  end

  it "cleans its workdir on failure and leaves nothing staged" do
    run = JobRun.create!(job_key: "produce_backup", trigger: "system")
    allow(ToolRunner).to receive(:run)
      .and_return(ToolRunner::Result.new(status: 1, stdout: "", stderr: "pg_dump: error"))

    expect { described_class.new(job_run: run).call }.to raise_error(FogBackup::Producer::Error, /pg_dump/)
    expect(FogBackup::Staging.job_dir(run.id)).not_to exist
    expect(FogBackup::Staging.backup_root.join("#{run.id}.tmp")).not_to exist
  end
end

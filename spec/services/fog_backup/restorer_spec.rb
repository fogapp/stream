# typed: false
# frozen_string_literal: true

require "rails_helper"

# The way back from a lost database, so it's proven the way it's used: a real
# artifact from the Producer, a real pg_restore over the live database, and
# the storage tree unpacked again. Rails.root points at a scratch folder so the
# storage tree being backed up and restored is this spec's, not a laptop's.
RSpec.describe FogBackup::Restorer do
  include RequestHelpers

  let(:scratch) { Pathname(Dir.mktmpdir("restorer")) }
  let(:poster) { scratch.join("storage/artwork/poster.webp") }

  before { allow(Rails).to receive(:root).and_return(scratch) }
  after { FileUtils.rm_rf(scratch) }

  def produce_and_stage!(as_v1: false)
    run = JobRun.create!(job_key: "produce_backup", trigger: "system")
    FogBackup::Producer.new(job_run: run).call
    FogBackup::Staging.restore_root.mkpath
    if as_v1
      rewrite_as_v1(FogBackup::Staging.artifact_path(run.id), FogBackup::Staging.pending_artifact)
    else
      FileUtils.cp(FogBackup::Staging.artifact_path(run.id), FogBackup::Staging.pending_artifact)
    end
  end

  # What Stream produced before fog-backup/2: the same artifact with its
  # storage tree zstd-compressed at files/storage.tar.zst and the manifest
  # saying fog-backup/1 (the -Fc dump restores either way).
  def rewrite_as_v1(source, destination)
    Dir.mktmpdir do |dir|
      system("tar", "-xf", source.to_s, "-C", dir, exception: true)
      system("zstd", "-q", "--rm", File.join(dir, "files/storage.tar"), "-o", File.join(dir, "files/storage.tar.zst"),
        exception: true)
      manifest = JSON.parse(File.read(File.join(dir, "manifest.json")))
      manifest["format"] = "fog-backup/1"
      storage = manifest["components"].find { |c| c["name"] == "storage" }
      storage["path"] = "files/storage.tar.zst"
      storage["bytes"] = File.size(File.join(dir, storage["path"]))
      storage["sha256"] = Digest::SHA256.file(File.join(dir, storage["path"])).hexdigest
      File.write(File.join(dir, "manifest.json"), JSON.generate(manifest))
      system("tar", "-cf", destination.to_s, "-C", dir, "manifest.json", "db/primary.dump", "files/storage.tar.zst",
        exception: true)
    end
  end

  context "with committed data" do
    # pg_restore --clean drops and recreates every table from another
    # process: it would wait forever on this example's own transaction.
    self.use_transactional_tests = false

    after do
      connection = ActiveRecord::Base.connection
      tables = connection.tables - %w[schema_migrations ar_internal_metadata]
      connection.execute("TRUNCATE #{tables.map { |table| connection.quote_table_name(table) }.join(', ')} RESTART IDENTITY CASCADE")
    end

    it "puts the database and the storage tree back as they were, once, and says so" do
      household = create_household(name: "The Harnesses")
      user = create_user(household: household, email: "ellie@example.com")
      poster.dirname.mkpath
      poster.write("poster bytes")
      produce_and_stage!
      FogBackup::Staging.arm!(confirm_identity: false, staged_by: "spec")

      # Life goes on after the backup: an edit, a new row, a lost file.
      household.update!(name: "Renamed since")
      create_household(name: "Made since")
      user.destroy!
      poster.delete

      # Siblings wait on the lock until the restore is done: it must still be
      # held after pg_restore, when the database connection has been renewed.
      held_late = nil
      allow(Trailers).to receive(:requeue_missing!) do
        held_late = ActiveRecord::Base.connection.select_value(
          "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND granted"
        ).to_i.positive?
      end

      expect(described_class.run_if_armed!).to be(true)

      expect(held_late).to be(true)
      expect(Household.pluck(:name)).to eq([ "The Harnesses" ])
      expect(User.sole.email).to eq("ellie@example.com")
      expect(poster.read).to eq("poster bytes")
      expect(FogBackup::Staging).not_to be_armed
      expect(FogBackup::Staging.pending_artifact).not_to exist
      expect(FogBackup::Staging.work_dir).not_to exist
      expect(FogBackup::Staging.receipt).to include("artifact_schema_version" => FogBackup::Manifest.code_schema_version.to_s)
      expect(ActivityEntry.where(event: "backup.restore.completed").count).to eq(1)

      # A sibling container booting behind this one finds nothing to do.
      expect(described_class.run_if_armed!).to be(false)
      expect(Household.count).to eq(1)
    end

    # Producers write fog-backup/2 only; a fog-backup/1 backup taken before
    # the switch must still restore.
    it "restores a fog-backup/1 artifact, its storage tree unpacked with zstd" do
      create_household(name: "From the old format")
      poster.dirname.mkpath
      poster.write("old poster bytes")
      produce_and_stage!(as_v1: true)
      FogBackup::Staging.arm!(confirm_identity: false, staged_by: "spec")

      create_household(name: "Made since")
      poster.delete
      allow(ToolRunner).to receive(:run).and_call_original

      expect(described_class.run_if_armed!).to be(true)

      expect(ToolRunner).to have_received(:run).with(array_including("tar", "--zstd", "-xf"), any_args)
      expect(Household.pluck(:name)).to eq([ "From the old format" ])
      expect(poster.read).to eq("old poster bytes")
      expect(FogBackup::Staging).not_to be_armed
    end
  end

  it "does nothing when an artifact is staged but not armed" do
    produce_and_stage!

    expect(described_class.run_if_armed!).to be(false)
    expect(FogBackup::Staging.pending_artifact).to exist
  end

  it "refuses an artifact of a format it doesn't know, and stays armed" do
    produce_and_stage!
    Dir.mktmpdir do |dir|
      system("tar", "-xf", FogBackup::Staging.pending_artifact.to_s, "-C", dir, exception: true)
      manifest = JSON.parse(File.read(File.join(dir, "manifest.json")))
      File.write(File.join(dir, "manifest.json"), JSON.generate(manifest.merge("format" => "fog-backup/9")))
      system("tar", "-cf", FogBackup::Staging.pending_artifact.to_s, "-C", dir,
        "manifest.json", "db/primary.dump", "files/storage.tar", exception: true)
    end
    FogBackup::Staging.arm!(confirm_identity: false, staged_by: "spec")
    create_household(name: "Still here")

    expect { described_class.run_if_armed! }.to raise_error(described_class::Error, %r{format "fog-backup/9"})

    expect(FogBackup::Staging).to be_armed
    expect(Household.pluck(:name)).to eq([ "Still here" ])
  end

  it "refuses a corrupt artifact loudly and stays armed, so boot stops rather than serving an empty instance" do
    FogBackup::Staging.restore_root.mkpath
    FogBackup::Staging.pending_artifact.write("not a tar")
    FogBackup::Staging.arm!(confirm_identity: false, staged_by: "spec")
    create_household(name: "Still here")

    expect { described_class.run_if_armed! }.to raise_error(described_class::Error, /preflight failed/)

    expect(FogBackup::Staging).to be_armed
    expect(Household.pluck(:name)).to eq([ "Still here" ])
  end
end

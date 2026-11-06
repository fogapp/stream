# typed: strict
# frozen_string_literal: true

module FogBackup
  # Builds one fog-backup/2 artifact into producer staging
  # (fog:docs/backup-contract.md): an uncompressed custom-format pg_dump of
  # the primary database with the container's own binary (dump tool matches
  # server by construction — the exact GitLab-2017 failure made impossible),
  # a plain tar of the storage tree, a manifest, and a single outer tar with
  # the manifest first.
  #
  # Nothing is compressed: fog keeps artifacts in a store that cuts them into
  # content-defined chunks and compresses each chunk itself. A payload
  # compressed whole reshuffles on every change and shares nothing with the
  # night before.
  #
  # Progress lands on the JobRun row so the /fog job-status endpoint (and the
  # console) can show what a long dump is doing.
  class Producer
    extend T::Sig

    class Error < StandardError; end

    DUMP_TIMEOUT = T.let(3600, Integer)
    TAR_TIMEOUT = T.let(3600, Integer)

    # Folders under storage/ the artifact leaves out: fog's own staging (an
    # artifact must never contain staged artifacts), what Stream can fetch
    # again — trailer videos (one per title) and the updated yt-dlp — and
    # seek-bar thumbnails, which it can render again from the file.
    EXCLUDED = T.let(%w[fog trailers tools trickplay].freeze, T::Array[String])

    # And within subtitles/, the copies of what's inside the media file:
    # image (PGS) tracks, hundreds of MB each on a Blu-ray remux, and fonts
    # an MKV carries for its ASS styling. Text tracks stay — small, and
    # OpenSubtitles downloads can't be made again. A restore puts all of
    # these back in the queue (Trailers, Trickplay and
    # Subtitles::Extractor .requeue_missing!).
    EXCLUDED_PATTERNS = T.let(%w[storage/subtitles/*/*.sup storage/subtitles/*/fonts].freeze, T::Array[String])

    DUMP_PATH = T.let("db/primary.dump", String)
    STORAGE_PATH = T.let("files/storage.tar", String)

    sig { params(job_run: JobRun).void }
    def initialize(job_run:)
      @job_run = job_run
      @workdir = T.let(Staging.backup_root.join("#{job_run.id}.tmp"), Pathname)
    end

    sig { returns(String) }
    def call
      Staging.sweep_stale!
      FileUtils.rm_rf(@workdir)
      @workdir.join("db").mkpath
      @workdir.join("files").mkpath

      progress("dumping primary database")
      dump_primary

      progress("archiving file state")
      archive_storage

      progress("writing manifest")
      manifest = Manifest.build(components: components)
      @workdir.join("manifest.json").write(JSON.pretty_generate(manifest))

      progress("assembling artifact")
      artifact = assemble

      "artifact #{ActiveSupport::NumberHelper.number_to_human_size(artifact[:bytes])}, sha256 #{artifact[:sha256].first(12)}"
    ensure
      FileUtils.rm_rf(@workdir)
    end

    private

    sig { params(message: String).void }
    def progress(message)
      @job_run.update!(message: message)
    end

    sig { void }
    def dump_primary
      config = ActiveRecord::Base.connection_db_config.configuration_hash
      argv = [
        "pg_dump", "-Fc", "-Z0", "--no-owner", "--no-privileges", "--no-comments",
        "-h", config[:host].to_s,
        "-p", (config[:port] || 5432).to_s,
        "-U", config[:username].to_s,
        "-d", config[:database].to_s,
        "-f", @workdir.join(DUMP_PATH).to_s
      ]
      run!(argv, timeout: DUMP_TIMEOUT, env: { "PGPASSWORD" => config[:password].to_s })
    end

    sig { void }
    def archive_storage
      # The storage tree relative to Rails.root, minus EXCLUDED.
      #
      # The worker keeps writing this tree (trickplay, artwork) while we read
      # it. GNU tar exits 1 for "file changed as we read it" / "file removed
      # before we read it" — the archive is still complete — and 2 for a real
      # failure. Writers put new output in a fresh versioned directory before
      # the row points at it, and the dump above predates this tar, so a
      # half-read file is one the restored database doesn't reference.
      #
      # A plain tar (fog-backup/2): fog's store compresses chunks itself.
      excludes = EXCLUDED.flat_map { |dir| [ "--exclude", "storage/#{dir}", "--exclude", "storage/#{dir}/*" ] } +
        EXCLUDED_PATTERNS.flat_map { |pattern| [ "--exclude", pattern ] }
      run!([
        "tar", *excludes,
        "-cf", @workdir.join(STORAGE_PATH).to_s,
        "-C", Rails.root.to_s, "storage"
      ], timeout: TAR_TIMEOUT, ok: [ 0, 1 ])
    end

    sig { returns(T::Array[Manifest::Component]) }
    def components
      [
        component("primary", DUMP_PATH, "db"),
        component("storage", STORAGE_PATH, "files")
      ]
    end

    sig { params(name: String, path: String, kind: String).returns(Manifest::Component) }
    def component(name, path, kind)
      file = @workdir.join(path)
      Manifest::Component.new(
        name: name, path: path, kind: kind,
        bytes: file.size,
        sha256: Digest::SHA256.file(file.to_s).hexdigest
      )
    end

    # The outer tar is uncompressed and lists the manifest first, so it can
    # be consumed as a forward-only stream with the manifest readable before
    # a byte of payload.
    sig { returns(T::Hash[Symbol, T.untyped]) }
    def assemble
      tmp_artifact = @workdir.join("artifact.tar")
      run!([
        "tar", "-cf", tmp_artifact.to_s, "-C", @workdir.to_s,
        "manifest.json", DUMP_PATH, STORAGE_PATH
      ], timeout: TAR_TIMEOUT)

      final_dir = Staging.job_dir(@job_run.id)
      FileUtils.rm_rf(final_dir)
      final_dir.mkpath
      FileUtils.mv(tmp_artifact.to_s, Staging.artifact_path(@job_run.id).to_s)

      info = {
        bytes: Staging.artifact_path(@job_run.id).size,
        sha256: Digest::SHA256.file(Staging.artifact_path(@job_run.id).to_s).hexdigest,
        created_at: Time.current.utc.iso8601
      }
      Staging.artifact_info_path(@job_run.id).write(JSON.generate(info))
      Staging.record_last_artifact(info)
      info
    end

    sig { params(argv: T::Array[String], timeout: Integer, env: T::Hash[String, String], ok: T::Array[Integer]).void }
    def run!(argv, timeout:, env: {}, ok: [ 0 ])
      result = ToolRunner.run(argv, timeout: timeout, env: env)
      return if ok.include?(result.status)

      raise Error, "#{argv.first} exited #{result.status}: #{result.stderr.presence || result.stdout}".truncate(500)
    end
  end
end

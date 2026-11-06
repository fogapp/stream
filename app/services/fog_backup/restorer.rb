# typed: strict
# frozen_string_literal: true

module FogBackup
  # Restore-on-boot (fog:docs/backup-contract.md): consume the staged, armed
  # artifact before the app serves traffic. Invoked from fog:release (fog's
  # release phase — single instance, no traffic) and from the docker
  # entrypoint (a container restart after the setup wizard armed a restore).
  #
  # Exactly one process restores: everything runs under a session-level
  # Postgres advisory lock, so when web, worker, and streamer containers all
  # boot through the entrypoint at once, one does the work and the others
  # find the marker gone when the lock frees.
  #
  # pg_restore runs as the app's own database role, so every restored object
  # is owned correctly — no post-restore REASSIGN OWNED fix-up.
  #
  # Every format Stream has produced restores (Manifest::ACCEPTED_FORMATS):
  # each component is read from the path its manifest entry names and
  # unpacked by its extension — fog-backup/1's files/storage.tar.zst with
  # zstd, fog-backup/2's files/storage.tar as is. pg_restore reads both
  # dumps (-Fc compressed or -Z0) unchanged.
  class Restorer
    extend T::Sig

    class Error < StandardError; end

    RESTORE_TIMEOUT = T.let(3600 * 2, Integer)
    LOCK_KEY = T.let("fog_backup_restore", String)

    # Runs the restore when one is staged and armed. Returns true when this
    # process performed a restore.
    sig { returns(T::Boolean) }
    def self.run_if_armed!
      return false unless Staging.armed?

      new.call
    end

    sig { returns(T::Boolean) }
    def call
      # The lock lives on a connection of its own: restore_primary reconnects
      # the working one, which would end the session and free the lock while
      # storage is still being unpacked — letting a waiting sibling restore
      # all over again.
      pool = ActiveRecord::Base.connection_pool
      lock = pool.checkout
      lock.execute("SELECT pg_advisory_lock(hashtext(#{lock.quote(LOCK_KEY)}))")
      begin
        # Re-check under the lock: a sibling process may have finished the
        # restore while this one waited.
        return false unless Staging.armed?

        restore!
        true
      ensure
        lock.execute("SELECT pg_advisory_unlock(hashtext(#{lock.quote(LOCK_KEY)}))")
        pool.checkin(lock)
      end
    end

    private

    sig { void }
    def restore!
      marker = Staging.marker
      preflight = Preflight.check(
        artifact_path: Staging.pending_artifact,
        confirm_identity: marker["confirm_identity"] == true
      )
      unless preflight.ok?
        # The marker stays armed: a half-diagnosed restore must block boot
        # loudly, not fall through to serving an empty instance.
        raise Error, "Restore preflight failed:\n  #{preflight.errors.join("\n  ")}"
      end
      manifest = T.must(preflight.manifest)

      work = Staging.work_dir
      FileUtils.rm_rf(work)
      work.mkpath

      extract_artifact(work)
      restore_primary(work, manifest)
      restore_files(work, manifest)
      Trailers.requeue_missing!
      Trickplay.requeue_missing!
      Subtitles::Extractor.requeue_missing!
      write_receipt(manifest)

      Activity.record(
        source: "fog", event: "backup.restore.completed",
        summary: "Restored from artifact created #{manifest.created_at} (#{manifest.git_sha&.first(12)})",
        payload: { artifact_created_at: manifest.created_at, artifact_git_sha: manifest.git_sha }
      )
      Staging.disarm!
    end

    sig { params(work: Pathname).void }
    def extract_artifact(work)
      run!([ "tar", "-xf", Staging.pending_artifact.to_s, "-C", work.to_s ])
    end

    sig { params(work: Pathname, manifest: Manifest::Parsed).void }
    def restore_primary(work, manifest)
      entry = manifest.components.find { |component| component["kind"].to_s == "db" }
      raise Error, "Artifact's manifest lists no db component" if entry.nil?

      dump = component_path(work, entry)
      raise Error, "Artifact has no #{entry["path"]}" unless dump.exist?

      config = ActiveRecord::Base.connection_db_config.configuration_hash
      run!([
        "pg_restore", "--clean", "--if-exists", "--no-owner", "--no-privileges",
        "-h", config[:host].to_s,
        "-p", (config[:port] || 5432).to_s,
        "-U", config[:username].to_s,
        "-d", config[:database].to_s,
        dump.to_s
      ], env: { "PGPASSWORD" => config[:password].to_s })
      # This session's cached views of the schema are now stale; drop them so
      # anything after the restore reads the restored truth.
      ActiveRecord::Base.connection.schema_cache.clear!
      ActiveRecord::Base.connection.reconnect!
    end

    # Unpacks each files component (the storage/ tree) relative to
    # Rails.root. The producer excluded storage/fog (Producer::EXCLUDED), so
    # the staging area (including the artifact being restored right now) is
    # never touched. An artifact without a files component is legal.
    sig { params(work: Pathname, manifest: Manifest::Parsed).void }
    def restore_files(work, manifest)
      manifest.components.select { |component| component["kind"].to_s == "files" }.each do |entry|
        archive = component_path(work, entry)
        raise Error, "Artifact has no #{entry["path"]}" unless archive.exist?

        path = entry["path"].to_s
        decompress =
          if path.end_with?(".tar.zst") then [ "--zstd" ]
          elsif path.end_with?(".tar") then []
          else raise Error, "Files component #{path} is neither .tar nor .tar.zst"
          end
        run!([ "tar", *decompress, "-xf", archive.to_s, "-C", Rails.root.to_s ])
      end
    end

    # A component's path inside the extracted artifact, as its manifest
    # entry names it. Preflight proved the entry exists with that digest; this
    # refuses a path that would reach outside the work directory.
    sig { params(work: Pathname, entry: T::Hash[String, T.untyped]).returns(Pathname) }
    def component_path(work, entry)
      path = entry["path"].to_s
      parts = path.split("/")
      if path.empty? || path.start_with?("/") || parts.any? { |part| part == ".." }
        raise Error, "Component path #{path.inspect} is not inside the artifact"
      end

      work.join(path)
    end

    sig { params(manifest: Manifest::Parsed).void }
    def write_receipt(manifest)
      Staging.restore_root.mkpath
      Staging.receipt_path.write(JSON.pretty_generate(
        restored_at: Time.current.utc.iso8601,
        artifact_created_at: manifest.created_at,
        artifact_git_sha: manifest.git_sha,
        artifact_schema_version: manifest.schema_version.to_s,
        restored_by_git_sha: StreamVersion.sha
      ))
    end

    sig { params(argv: T::Array[String], env: T::Hash[String, String]).void }
    def run!(argv, env: {})
      result = ToolRunner.run(argv, timeout: RESTORE_TIMEOUT, env: env)
      return if result.success?

      raise Error, "#{argv.first} exited #{result.status}: #{result.stderr.presence || result.stdout}".truncate(1000)
    end
  end
end

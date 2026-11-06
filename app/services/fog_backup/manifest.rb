# typed: strict
# frozen_string_literal: true

module FogBackup
  # The artifact's self-description (fog:docs/backup-contract.md). Built by
  # the producer, parsed by preflight; fog stores it verbatim beside the
  # artifact. Plaintext by design — a backup you can't identify without keys
  # is a backup you can't manage.
  module Manifest
    extend T::Sig

    # What the producer writes. fog-backup/2 is fog-backup/1 with its
    # payloads uncompressed (an -Z0 custom-format dump, plain tars), so fog's
    # deduplicating store can share chunks between nights.
    FORMAT = T.let("fog-backup/2", String)
    # What preflight and the restorer accept: every format Stream has ever
    # produced, so any backup it has made can come back.
    ACCEPTED_FORMATS = T.let(%w[fog-backup/1 fog-backup/2].freeze, T::Array[String])
    APP = T.let("stream", String)

    # The env values whose loss bricks a restore. Only their fingerprints
    # travel — enough for preflight to fail loudly on mismatch, never enough
    # to leak the value.
    FINGERPRINTED_SECRETS = T.let(%w[
      AR_ENCRYPTION_PRIMARY_KEY
      AR_ENCRYPTION_DETERMINISTIC_KEY
      AR_ENCRYPTION_KEY_DERIVATION_SALT
      SECRET_KEY_BASE
    ].freeze, T::Array[String])

    class Component < T::Struct
      const :name, String
      const :path, String
      const :kind, String
      const :bytes, Integer
      const :sha256, String
    end

    sig { params(components: T::Array[Component]).returns(T::Hash[Symbol, T.untyped]) }
    def self.build(components:)
      {
        format: FORMAT,
        app: APP,
        created_at: Time.current.utc.iso8601,
        produced_by: { git_sha: StreamVersion.sha, schema_version: code_schema_version.to_s },
        pg: pg_info,
        components: components.map { |c| { name: c.name, path: c.path, kind: c.kind, bytes: c.bytes, sha256: c.sha256 } },
        external: external_sections,
        excluded: %w[cache queue],
        identity: { host: ENV["STREAM_HOST"].presence, webauthn_rp_id: WebauthnRelyingParty.configured_rp_id },
        secrets_fingerprint: secrets_fingerprint
      }
    end

    # The code's newest migration, read from db/migrate rather than the
    # database — preflight runs against a database that may not have a schema
    # yet (restore-at-create lands before db:prepare).
    sig { returns(Integer) }
    def self.code_schema_version
      paths = ActiveRecord::Migrator.migrations_paths
      ActiveRecord::MigrationContext.new(paths).migrations.map(&:version).max || 0
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def self.pg_info
      connection = ActiveRecord::Base.connection
      server_num = connection.select_value("SELECT current_setting('server_version_num')").to_i
      {
        server_major: server_num / 10_000,
        dump_tool: dump_tool_version,
        extensions: installed_extensions
      }
    end

    sig { returns(T::Hash[String, String]) }
    def self.installed_extensions
      rows = ActiveRecord::Base.connection.select_rows(
        "SELECT extname, extversion FROM pg_extension WHERE extname <> 'plpgsql'"
      )
      rows.to_h { |name, version| [ name.to_s, version.to_s ] }
    end

    sig { returns(T.nilable(String)) }
    def self.dump_tool_version
      ToolRunner.version("pg_dump")
    end

    sig { returns(T::Hash[String, String]) }
    def self.secrets_fingerprint
      FINGERPRINTED_SECRETS.each_with_object({}) do |key, out|
        value = ENV[key].presence
        next if value.nil?

        out[key] = "sha256:#{Digest::SHA256.hexdigest(value).first(12)}"
      end
    end

    # State deliberately outside the artifact. Stream owns no bulk files: the
    # media libraries are fog Content folders (a NAS share) and the cache is
    # regenerable scratch — neither belongs in this artifact; media is covered by
    # fog's own Files snapshots. Nothing to declare until Stream keeps files
    # of its own.
    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.external_sections
      []
    end

    # ---- parsing (preflight side) ----

    class Parsed < T::Struct
      extend T::Sig

      const :raw, T::Hash[String, T.untyped]

      sig { returns(String) }
      def format = raw["format"].to_s

      sig { returns(String) }
      def app = raw["app"].to_s

      sig { returns(T.nilable(String)) }
      def created_at = raw["created_at"]&.to_s

      sig { returns(Integer) }
      def schema_version = raw.dig("produced_by", "schema_version").to_i

      sig { returns(T.nilable(String)) }
      def git_sha = raw.dig("produced_by", "git_sha")&.to_s

      sig { returns(T::Hash[String, String]) }
      def extensions
        (raw.dig("pg", "extensions") || {}).to_h { |k, v| [ k.to_s, v.to_s ] }
      end

      sig { returns(T::Array[T::Hash[String, T.untyped]]) }
      def components = Array(raw["components"])

      sig { returns(T::Hash[String, String]) }
      def secrets_fingerprint
        (raw["secrets_fingerprint"] || {}).to_h { |k, v| [ k.to_s, v.to_s ] }
      end

      sig { returns(T.nilable(String)) }
      def identity_host = raw.dig("identity", "host")&.to_s.presence
    end

    sig { params(json: String).returns(Parsed) }
    def self.parse(json)
      Parsed.new(raw: JSON.parse(json))
    end
  end
end

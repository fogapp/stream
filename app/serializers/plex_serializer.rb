# typed: strict
# frozen_string_literal: true

module PlexSerializer
  extend T::Sig

  # Never the token.
  sig { params(connection: T.nilable(PlexConnection)).returns(T::Hash[Symbol, T.untyped]) }
  def self.connection_json(connection)
    return { connected: false } if connection.nil?

    {
      connected: true, server_url: connection.server_url, server_name: connection.server_name,
      sync_enabled: connection.sync_enabled, last_synced_at: connection.last_synced_at,
      last_tested_at: connection.last_tested_at, last_test_ok: connection.last_test_ok,
      last_test_message: connection.last_test_message,
      users: connection.plex_user_mappings.order(plex_admin: :desc, plex_name: :asc).map do |mapping|
        { id: mapping.id, plex_name: mapping.plex_name, plex_admin: mapping.plex_admin, profile_id: mapping.profile_id }
      end
    }
  end

  sig { params(import: PlexImport).returns(T::Hash[Symbol, T.untyped]) }
  def self.import_json(import)
    {
      id: import.id, dry_run: import.dry_run, status: import.status_enum, counts: import.counts,
      unmatched: import.unmatched, users: import.users, error: import.error,
      started_at: import.started_at, finished_at: import.finished_at, created_at: import.created_at
    }
  end
end

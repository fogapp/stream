# typed: strict
# frozen_string_literal: true

module NotificationSerializer
  extend T::Sig

  sig { params(rows: T::Array[Notification], unread_count: Integer).returns(T::Hash[Symbol, T.untyped]) }
  def self.index_json(rows, unread_count:)
    { unread_count: unread_count, notifications: rows.map { |row| notification_json(row) } }
  end

  sig { params(row: Notification).returns(T::Hash[Symbol, T.untyped]) }
  def self.notification_json(row)
    {
      id: row.id, kind: row.kind, icon: row.icon, title: row.title,
      path: row.path, read_at: row.read_at, created_at: row.created_at
    }
  end
end

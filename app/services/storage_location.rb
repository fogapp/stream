# typed: strict
# frozen_string_literal: true

require "sys/filesystem"

# Validates and describes a directory the operator points Stream at — a
# library root under /media, the cache volume, a scratch folder.
#
# The failure modes here are the ones a person hits when pointing an app at a
# NAS: the mount isn't visible inside the container, it's mounted read-only,
# or it silently isn't mounted at all. Each of those gets a specific,
# actionable message rather than a generic "invalid path", because the whole
# point of putting this in the UI is that the person doing it shouldn't need
# to read a stack trace.
module StorageLocation
  extend T::Sig

  class Report < T::Struct
    extend T::Sig

    const :path, String
    const :ok, T::Boolean
    const :message, String
    const :exists, T::Boolean, default: false
    const :writable, T::Boolean, default: false
    const :total_bytes, T.nilable(Integer), default: nil
    const :free_bytes, T.nilable(Integer), default: nil

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h
      { path:, ok:, message:, exists:, writable:, total_bytes:, free_bytes: }
    end
  end

  # `writable: false` checks visibility only — the right question for a
  # folder Stream only reads (a client's completed directory).
  sig { params(candidate: String, writable: T::Boolean).returns(Report) }
  def self.inspect_path(candidate, writable: true)
    path = candidate.to_s.strip
    return Report.new(path: path, ok: false, message: "Enter a directory path.") if path.blank?

    unless path.start_with?("/")
      return Report.new(path: path, ok: false,
        message: "Use an absolute path — one starting with / — as seen from inside the Stream container.")
    end

    pathname = Pathname.new(path)
    exists = pathname.directory?

    unless exists
      return Report.new(path: path, ok: false, exists: false,
        message: "That directory isn't visible to Stream. If it's a NAS mount or another app's folder, " \
                 "make sure it's mounted into the container (add it as a volume in Fog) first.")
    end

    can_write = File.writable?(pathname) ? true : false
    if writable && !can_write
      return Report.new(path: path, ok: false, exists: true, writable: false,
        message: "Stream can see that directory but can't write to it. Check the share is mounted " \
                 "read-write and that its owner allows uid 1000.")
    end

    stats = disk_stats(pathname)
    Report.new(
      path: path, ok: true, exists: true, writable: can_write,
      message: "Ready. #{human_bytes(stats[:free])} free of #{human_bytes(stats[:total])}.",
      total_bytes: stats[:total], free_bytes: stats[:free]
    )
  end

  sig { params(pathname: Pathname).returns(T::Hash[Symbol, T.nilable(Integer)]) }
  def self.disk_stats(pathname)
    stat = Sys::Filesystem.stat(pathname.to_s)
    { total: stat.bytes_total, free: stat.bytes_available }
  rescue StandardError
    # An exotic mount: degrade to "we can't tell" rather than blocking a
    # perfectly good path.
    { total: nil, free: nil }
  end
  private_class_method :disk_stats

  sig { params(bytes: T.nilable(Integer)).returns(String) }
  def self.human_bytes(bytes)
    return "unknown space" if bytes.nil?

    ActiveSupport::NumberHelper.number_to_human_size(bytes).to_s
  end
end

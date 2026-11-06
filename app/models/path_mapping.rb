# typed: strict
# frozen_string_literal: true

# "What Sonarr calls /tv, Stream calls /media/tv" (PROPOSAL §5.1, hook's
# path mappings). Longest remote prefix wins. A path no row here holds is
# tried against the translations fog hands over for the apps Stream uses
# (fog:docs/files-contract.md, "Wiring") — under fog, a Sonarr it runs
# needs no row at all.
class PathMapping < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  normalizes :remote_prefix, :local_prefix, with: ->(path) { path.to_s.strip.chomp("/") }

  validates :remote_prefix, :local_prefix, presence: true, format: { with: %r{\A/[^\0\n]*\z}, message: "must be an absolute path" }
  validates :remote_prefix, uniqueness: { scope: :household_id }
  validate :local_prefix_visible

  # The path as Stream sees it, or the path unchanged when no mapping applies.
  sig { params(household_id: String, path: String).returns(String) }
  def self.translate(household_id, path)
    mapping = unscoped.where(household_id: household_id).to_a
      .select { |candidate| path == candidate.remote_prefix || path.start_with?("#{candidate.remote_prefix}/") }
      .max_by { |candidate| candidate.remote_prefix.length }
    return "#{mapping.local_prefix}#{path.delete_prefix(mapping.remote_prefix)}" if mapping

    fog_translate(path) || path
  end

  sig { params(path: String).returns(T.nilable(String)) }
  def self.fog_translate(path)
    rows = T.let(Rails.cache.fetch("fog:path_rows", expires_in: 1.minute, skip_nil: true) { Fog::Api.new.path_rows },
      T.nilable(T::Array[T::Hash[String, String]]))
    row = Array(rows).select { |r| r["remote"].present? && (path == r["remote"] || path.start_with?("#{r['remote'].to_s.chomp('/')}/")) }
      .max_by { |r| r["remote"].to_s.length }
    return nil if row.nil?

    "#{row['local'].to_s.chomp('/')}#{path.delete_prefix(row['remote'].to_s.chomp('/'))}"
  end

  private

  sig { void }
  def local_prefix_visible
    return if local_prefix.blank?

    report = StorageLocation.inspect_path(local_prefix, writable: false)
    errors.add(:local_prefix, report.message) unless report.ok
  end
end

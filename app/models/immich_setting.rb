# typed: strict
# frozen_string_literal: true

# The household's Immich connection (PROPOSAL §5.4): read-only, entered in
# Settings, the key stored encrypted and never sent back.
class ImmichSetting < ApplicationRecord
  extend T::Sig
  include HouseholdScoped
  include ConnectionTested

  encrypts :api_key

  normalizes :url, with: ->(url) { url.strip.chomp("/") }
  normalizes :immich_path_prefix, :local_path_prefix, with: ->(path) { path.strip.chomp("/").presence }

  validates :url, presence: true, format: { with: %r{\Ahttps?://[^\s]+\z}, message: "must start with http:// or https://" }
  validates :api_key, presence: true

  # Where Stream finds a file Immich names.
  sig { params(immich_path: String).returns(String) }
  def local_path(immich_path)
    from = immich_path_prefix
    to = local_path_prefix
    return immich_path if from.nil? || to.nil? || !immich_path.start_with?("#{from}/")

    "#{to}#{immich_path.delete_prefix(from)}"
  end
end

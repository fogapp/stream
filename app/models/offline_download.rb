# typed: strict
# frozen_string_literal: true

# A title saved into one browser to watch offline (PROPOSAL §11 Phase 6):
# either the original, when this browser plays it as-is, or its optimized
# version. The download URL signs this row, so it stops working when the
# row is deleted or expires; the bytes themselves stay in the browser until
# it's removed there.
class OfflineDownload < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  LIFETIME = T.let(30.days, ActiveSupport::Duration)

  belongs_to :profile
  belongs_to :playable, polymorphic: true
  belongs_to :media_file
  belongs_to :optimized_version, optional: true

  scope :live, -> { where(expires_at: Time.current..) }

  # What the download serves: the optimized version's file or the original.
  sig { returns(T.nilable(Pathname)) }
  def source_path
    version = optimized_version
    return version.ready? ? version.path : nil if version

    media_file&.servable_path
  end

  sig { returns(String) }
  def extension = optimized_version_id ? "mp4" : File.extname(media_file&.path.to_s).delete(".").downcase

  sig { returns(String) }
  def mime_type = extension == "webm" ? "video/webm" : "video/mp4"
end

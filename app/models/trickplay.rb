# typed: strict
# frozen_string_literal: true

# A file's seek-bar thumbnails (PROPOSAL §5.5): one frame every
# interval_seconds, tiled into WebP sprite sheets of columns × rows.
class Trickplay < ApplicationRecord
  extend T::Sig

  belongs_to :media_file

  after_destroy_commit :remove_files

  sig { returns(Pathname) }
  def self.root
    Pathname.new(ENV.fetch("STREAM_STORAGE_DIR") { Rails.root.join("storage").to_s }).join("trickplay")
  end

  sig { returns(Pathname) }
  def directory = self.class.root.join(media_file_id.to_s)

  sig { params(index: Integer).returns(Pathname) }
  def sheet(index) = directory.join(version.to_s, "sheet-#{index}.webp")

  # After a restore (FogBackup::Restorer): backups leave the sprite sheets
  # out, since they can be rendered again from the file, so one whose sheets
  # didn't come back is rebuilt — and isn't offered to the player until then.
  sig { void }
  def self.requeue_missing!
    where.not(version: 0).find_each do |trickplay|
      next if trickplay.sheet(0).file?

      trickplay.update!(version: 0)
      AnalyzeMediaFileJob.perform_later(trickplay.media_file_id)
    end
  end

  private

  sig { void }
  def remove_files
    FileUtils.rm_rf(directory)
  end
end

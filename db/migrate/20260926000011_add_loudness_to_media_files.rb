# typed: false
# frozen_string_literal: true

# Loudness (PROPOSAL §5.5): EBU R128 integrated loudness and true peak of
# the first audio track, so the player can bring quiet and loud files to
# the same level without converting anything.
class AddLoudnessToMediaFiles < ActiveRecord::Migration[8.1]
  def change
    add_column :media_files, :loudness_lufs, :float
    add_column :media_files, :true_peak_dbfs, :float
  end
end

# typed: false
# frozen_string_literal: true

# The keyframe index (PROPOSAL §5.3): every video keyframe's presentation
# time in milliseconds, so Phase 2's remux playlists are exact before ffmpeg
# runs and a seek maps straight to a segment. A two-hour film with 2 s GOPs
# is ~3,600 integers.
class AddKeyframesToMediaFiles < ActiveRecord::Migration[8.1]
  def change
    add_column :media_files, :keyframes, :integer, array: true
    # cues (Matroska), stss (MP4), packets (ffprobe scan): where it came from.
    add_column :media_files, :keyframes_source, :string
  end
end

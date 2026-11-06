# frozen_string_literal: true

# The subtitle files beside a video ("Heat (1995).en.srt"), as the scanner
# last saw them (docs/PERF_PROPOSAL.md › P3), so pressing Play never lists
# a folder on the NAS. nil: not seen by a scan since this column arrived —
# listed once on first use and kept.
class AddSidecarSubtitlesToMediaFiles < ActiveRecord::Migration[8.1]
  def change
    add_column :media_files, :sidecar_subtitles, :jsonb
  end
end

# frozen_string_literal: true

# How long a session's segments aim to be (Playback::SegmentPlan), fixed
# when it starts: the plan is rebuilt from rows on every request, so a
# change of target on deploy would renumber the segments under a session
# already playing. Sessions from before keep 6 s; new ones are 2 s
# (docs/PERF_PROPOSAL.md › P10).
class AddSegmentTargetMsToPlaybackSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :playback_sessions, :segment_target_ms, :integer, default: 6_000, null: false
  end
end

# typed: strict
# frozen_string_literal: true

# Something that happened while a session played (PROPOSAL §4.4): the raw
# material for the Playback decisions page and for debugging a bad night.
class PlaybackEvent < ApplicationRecord
  extend T::Sig

  class Kind < T::Enum
    include ApplicationEnum
    enums do
      Start = new("start")
      Seek = new("seek")
      Stall = new("stall")
      Error = new("error")
      Stop = new("stop")
      # A Grid channel change (PROPOSAL §7.7): how long from the key to
      # the first frame, and whether the channel had been tuned ahead.
      Tune = new("tune")
      # A Grid program giving way to the next (PROPOSAL §7.7): how long
      # from the old one's end to the new one's first frame, what noticed
      # the end (via: ended, part, watchdog — the picture stuck at its end
      # — or gap, after a slate), and whether the next was tuned ahead.
      Transition = new("transition")
      # From pressing Play to the first frame, with where the time went
      # (docs/PERF_PROPOSAL.md › P1): the session answered, the playlist,
      # the init segment, the first fragment, the picture.
      Startup = new("startup")
      # The player got itself going again without anyone noticing, or
      # nearly: a hole in the buffer hopped, a fragment fetched again, a
      # frozen picture reloaded. Not a failure — but a session with many
      # is a stream that isn't right.
      Recovery = new("recovery")
      # A native player's own totals when the play ends (AVPlayer's access
      # log, docs/APPLETV_STALLS.md › R0): stalls it counted, frames it
      # dropped, seconds watched, the bitrate it saw, its startup time.
      Summary = new("summary")
    end
  end

  belongs_to :playback_session

  attribute :kind, Kind
end

# typed: strict
# frozen_string_literal: true

module Media
  # Where a file's whole-file analysis (trickplay, loudness, subtitles)
  # waits on the heavy queue, which does two at a time (config/queue.yml).
  # A library's first scan queues every file it has at once — 40,000 jobs,
  # months of work — and a file that arrives tonight must not wait behind
  # all of it: what's new goes first, the back catalogue after, and what
  # someone pressed Play for ahead of both (KeyframeIndex.scan_later).
  # Solid Queue takes the lowest number first.
  module AnalysisPriority
    extend T::Sig

    URGENT = -10
    NEW = 0
    BACKLOG = 10
    # A file written this recently is an arrival, whenever it was scanned.
    RECENT = T.let(30.days, ActiveSupport::Duration)

    sig { params(file: MediaFile).returns(Integer) }
    def self.for(file) = file.mtime > RECENT.ago ? NEW : BACKLOG
  end
end

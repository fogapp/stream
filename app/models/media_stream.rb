# typed: strict
# frozen_string_literal: true

# One track of a media file as ffprobe saw it at scan time (PROPOSAL §4.1),
# or of a live stream as its probe saw it when it was saved (§7.8). The
# decision engine reads these rows and never probes at play time (CLAUDE.md
# invariant 4), so everything it needs is a column here.
class MediaStream < ApplicationRecord
  extend T::Sig

  class Kind < T::Enum
    include ApplicationEnum
    enums do
      Video = new("video")
      Audio = new("audio")
      Subtitle = new("subtitle")
      Attachment = new("attachment")
      Data = new("data")
    end
  end

  class HdrFormat < T::Enum
    include ApplicationEnum
    enums do
      Hdr10 = new("hdr10")
      Hdr10Plus = new("hdr10_plus")
      Hlg = new("hlg")
      DolbyVision = new("dolby_vision")
    end
  end

  # One or the other, never both (media_streams_one_owner).
  belongs_to :media_file, optional: true, inverse_of: :media_streams
  belongs_to :live_stream, optional: true, inverse_of: :media_streams

  attribute :kind, Kind
  attribute :hdr_format, HdrFormat, allow_nil: true

  validates :index, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end

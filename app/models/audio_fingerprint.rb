# typed: strict
# frozen_string_literal: true

class AudioFingerprint < ApplicationRecord
  extend T::Sig

  class Segment < T::Enum
    include ApplicationEnum
    enums do
      Head = new("head")
      Tail = new("tail")
      # All of it: what a later episode's recap is cut from.
      Whole = new("whole")
    end
  end

  belongs_to :media_file

  attribute :segment, Segment
end

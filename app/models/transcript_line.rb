# typed: strict
# frozen_string_literal: true

class TranscriptLine < ApplicationRecord
  extend T::Sig

  belongs_to :transcript
  belongs_to :media_file
end

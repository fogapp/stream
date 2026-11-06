# typed: strict
# frozen_string_literal: true

class ClipPerson < ApplicationRecord
  extend T::Sig

  belongs_to :clip
  belongs_to :home_person
end

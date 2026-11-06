# typed: strict
# frozen_string_literal: true

# What one profile always skips in one show (PROPOSAL §4.4, §7.3).
class ShowPreference < ApplicationRecord
  extend T::Sig

  belongs_to :profile
  belongs_to :show
end

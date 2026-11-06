# typed: strict
# frozen_string_literal: true

class ProfileNotice < ApplicationRecord
  extend T::Sig

  belongs_to :profile
  belongs_to :subject, polymorphic: true
end

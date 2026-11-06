# typed: strict
# frozen_string_literal: true

class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :household

  validates :kind, :title, :dedupe_key, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :unread, -> { where(read_at: nil) }
end

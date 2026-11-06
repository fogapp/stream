# typed: strict
# frozen_string_literal: true

# Every few minutes, each library's quick look for what's arrived
# (Libraries::ChangeDetector). Fans out only.
class DetectLibraryChangesJob < ApplicationJob
  extend T::Sig

  queue_as :default

  sig { void }
  def perform
    ids = Library.unscoped.pluck(:id)
    ActiveJob.perform_all_later(ids.map { |id| DetectLibraryChangeJob.new(id) }) if ids.any?
  end
end

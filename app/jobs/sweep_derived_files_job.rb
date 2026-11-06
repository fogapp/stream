# typed: strict
# frozen_string_literal: true

# Removes what Stream made from files that are gone (Media::DerivedFiles):
# after a library is deleted, and weekly for anything else left behind.
class SweepDerivedFilesJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: -> { "sweep_derived_files" }

  sig { void }
  def perform
    removed = Media::DerivedFiles.sweep
    return if removed.zero?

    Activity.record(source: "library", event: "derived_files.swept",
      summary: "Removed thumbnails, subtitles and optimized versions of #{removed} file#{removed == 1 ? '' : 's'} no longer in a library")
  end
end

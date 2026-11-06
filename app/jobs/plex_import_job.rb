# typed: strict
# frozen_string_literal: true

# Runs one Plex dry run or import (PROPOSAL §7.4). One at a time per
# household: two imports racing would count every view twice.
class PlexImportJob < ApplicationJob
  extend T::Sig

  queue_as :sync
  limits_concurrency to: 1, key: ->(import_id) { "plex_import:#{PlexImport.unscoped.where(id: import_id).pick(:household_id)}" },
    duration: 2.hours

  sig { params(import_id: String).void }
  def perform(import_id)
    import = PlexImport.unscoped.find_by(id: import_id)
    return if import.nil? || import.finished?

    Plex::Migration.new(import).call
  end
end

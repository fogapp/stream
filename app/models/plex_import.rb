# typed: strict
# frozen_string_literal: true

# One dry run or import from Plex (PROPOSAL §7.4): what matched, what
# didn't, and what changed, kept so the page can show it and a re-sync can
# be compared with the last.
class PlexImport < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  class Status < T::Enum
    include ApplicationEnum
    enums do
      Queued = new("queued")
      Running = new("running")
      Succeeded = new("succeeded")
      Failed = new("failed")
    end
  end

  # How many unmatched titles the report keeps.
  UNMATCHED_KEPT = 300

  attribute :status, Status

  sig { returns(T::Boolean) }
  def finished? = [ Status::Succeeded, Status::Failed ].include?(status_enum)
end

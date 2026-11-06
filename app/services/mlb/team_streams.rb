# typed: strict
# frozen_string_literal: true

module Mlb
  # Each club's MLB.tv broadcast as a stream (PROPOSAL §7.8): one per team
  # and household, playing whatever game the team is on in. Made for every
  # club when the account is saved, so a Grid channel can show one, and on
  # demand when Baseball plays one that isn't there yet.
  module TeamStreams
    extend T::Sig

    sig { params(household_id: String, team_id: Integer, name: String).returns(LiveStream) }
    def self.for(household_id, team_id, name)
      existing = LiveStream.unscoped.find_by(household_id: household_id, mlb_team_id: team_id)
      return existing if existing

      LiveStream.create!(household_id: household_id, mlb_team_id: team_id, name: name, kind: LiveStream::Kind::Mlb.serialize)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      # Made a moment ago by another request.
      LiveStream.unscoped.find_by!(household_id: household_id, mlb_team_id: team_id)
    end

    sig { params(household_id: String).void }
    def self.ensure!(household_id)
      Schedule.new.teams.each { |team| self.for(household_id, team.fetch("id"), team.fetch("name")) }
    end
  end
end

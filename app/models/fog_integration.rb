# typed: strict
# frozen_string_literal: true

# An app fog connected to Stream (FogIntegrations): which offer it took and
# the API token minted for it. Its id is the integration's id fog keeps.
class FogIntegration < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  # What Stream offers (fog.yaml `integrations.offers`): `library` is the
  # admin's full access, for an app that delivers files and starts scans;
  # `viewing` is read-only, for an app that shows what is playing.
  class Offer < T::Enum
    include ApplicationEnum
    enums do
      Library = new("library")
      Viewing = new("viewing")
    end
  end

  belongs_to :api_token, optional: true

  attribute :offer, Offer

  validates :consumer, presence: true
end

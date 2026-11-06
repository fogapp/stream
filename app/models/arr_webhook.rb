# typed: strict
# frozen_string_literal: true

# The household's Sonarr/Radarr webhook (PROPOSAL §5.1). Its token is the
# credential: the URL Sonarr posts to carries it, since a Connect webhook
# can't be trusted to send a header.
class ArrWebhook < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  encrypts :token, deterministic: true

  before_validation :mint_token, on: :create
  validates :token, presence: true

  sig { params(household: Household).returns(ArrWebhook) }
  def self.for(household) = for_household!(household)

  sig { void }
  def regenerate!
    update!(token: self.class.fresh_token)
  end

  sig { returns(String) }
  def self.fresh_token = SecureRandom.alphanumeric(32)

  private

  sig { void }
  def mint_token
    self.token = self.class.fresh_token if token.blank?
  end
end

# typed: strict
# frozen_string_literal: true

# The provider half of fog-integration/1 (fog:docs/integrations-contract.md):
# fog asks Stream for what another app on the box needs, Stream mints it for
# that app alone, and fog puts it in the app's environment.
#
# Two offers, one per thing an operator would connect: `library` mints a
# full token, for an app that delivers files, starts scans and reads the
# catalog as Stream's admin (Hook); `viewing` mints a read-only token, for an
# app that shows what is playing, what is next and what is new without
# changing anything (a start page). Both are in the name of the household's
# first admin, as a token has to be in someone's and the stats and scans
# they call are admin-only. Choosing the app on fog's Integrations tab is the
# operator's say-so — fog's operators are Stream's admins — and fog
# authenticates with FOG_API_TOKEN.
#
# An integration's id is its FogIntegration's: fog keeps it opaque and names
# it again to read the status of, or revoke, the integration.
module FogIntegrations
  extend T::Sig

  class Error < StandardError; end
  class NotFound < Error; end

  # A fog app name.
  SLUG = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  class Minted < T::Struct
    const :id, String
    const :secrets, T::Hash[String, String]
  end

  class Status < T::Struct
    const :id, String
    const :active, T::Boolean
    const :created_at, ActiveSupport::TimeWithZone
    const :last_activity_at, T.nilable(ActiveSupport::TimeWithZone)
  end

  sig { params(consumer: String, offer: String).returns(Minted) }
  def self.connect(consumer:, offer:)
    chosen = FogIntegration::Offer.try_deserialize(offer)
    if chosen.nil?
      raise Error, "Stream offers no #{offer.inspect} — it offers #{FogIntegration::Offer.values.map(&:serialize).join(", ")}"
    end
    raise Error, "#{consumer.inspect} is not an app name" unless SLUG.match?(consumer)

    household = Household.first
    raise Error, "Stream has no household yet — open it and finish setup first" if household.nil?

    owner = User.household_members.where(household: household, role: User::Role::Admin.serialize).order(:created_at).first
    raise Error, "Stream has no admin yet — sign in to Stream once first" if owner.nil?

    ActiveRecord::Base.transaction do
      token = ApiToken.generate(user: owner, name: "fog: #{consumer}", scope: scope_for(chosen))
      raise Error, token.api_token.errors.full_messages.to_sentence unless token.api_token.persisted?

      integration = FogIntegration.create!(household: household, consumer: consumer, offer: chosen.serialize,
        api_token: token.api_token)
      Activity.record(source: "fog", event: "integration.connected", household_id: household.id,
        summary: "fog connected #{consumer} to Stream's #{chosen} offer: a new #{scope_for(chosen)} API token for #{owner.name}")
      Minted.new(id: integration.id, secrets: { secret_for(chosen) => token.token })
    end
  end

  # Active while the token still works: a person revoking it in Settings ›
  # API tokens shows here as inactive, and fog offers to reconnect.
  sig { params(id: String).returns(Status) }
  def self.status(id)
    integration = find(id)
    token = integration.api_token
    Status.new(id: id, active: !token.nil? && !token.expired?, created_at: integration.created_at,
      last_activity_at: token&.last_used_at)
  end

  # The token goes, as a person's own revoke would, and the row with it: fog
  # takes the 404 that follows as already done.
  sig { params(id: String).void }
  def self.disconnect(id)
    integration = find(id)
    ActiveRecord::Base.transaction do
      integration.api_token&.destroy!
      integration.destroy!
    end
    Activity.record(source: "fog", event: "integration.revoked", household_id: integration.household_id,
      summary: "fog disconnected #{integration.consumer} from Stream: its API token is revoked")
  end

  sig { params(offer: FogIntegration::Offer).returns(ApiToken::Scope) }
  def self.scope_for(offer)
    case offer
    when FogIntegration::Offer::Library then ApiToken::Scope::Full
    when FogIntegration::Offer::Viewing then ApiToken::Scope::Read
    else T.absurd(offer)
    end
  end
  private_class_method :scope_for

  # The secret name the offer declares in fog.yaml.
  sig { params(offer: FogIntegration::Offer).returns(String) }
  def self.secret_for(offer)
    case offer
    when FogIntegration::Offer::Library then "STREAM_API_TOKEN"
    when FogIntegration::Offer::Viewing then "STREAM_READ_TOKEN"
    else T.absurd(offer)
    end
  end
  private_class_method :secret_for

  sig { params(id: String).returns(FogIntegration) }
  def self.find(id)
    raise NotFound, "no such integration" unless id.match?(UUID)

    integration = FogIntegration.unscoped.includes(:api_token).find_by(id: id)
    raise NotFound, "no such integration" if integration.nil?

    integration
  end
  private_class_method :find
end

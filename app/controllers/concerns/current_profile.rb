# typed: strict
# frozen_string_literal: true

# Which profile a request watches as (PROPOSAL §4.4, §7.4): the one this
# browser chose (a signed token in X-Stream-Profile, PIN already checked);
# else this device's default (X-Stream-Device); else the household's first
# profile without a PIN.
module CurrentProfile
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { Api::V1::BaseController }

  private

  sig { returns(Profile) }
  def current_profile!
    @current_profile ||= T.let(chosen_profile || device_default_profile || Profile.open_default_for(current_household!),
      T.nilable(Profile))
  end

  # The profile this browser chose, if its token still holds.
  sig { returns(T.nilable(Profile)) }
  def chosen_profile
    token = request.headers["X-Stream-Profile"].to_s
    token.present? ? ProfileTokens.verify(token, current_household!.id) : nil
  end

  sig { returns(T.nilable(Profile)) }
  def device_default_profile
    current_device&.default_profile
  end

  # The browser's device row; made on first sight when asked to.
  sig { params(create: T::Boolean).returns(T.nilable(Device)) }
  def current_device(create: false)
    key = request.headers["X-Stream-Device"].to_s.first(64)
    return nil if key.blank?

    Device.find_by(client_key: key) || (create ? Device.create!(client_key: key, name: Device.name_from(request.user_agent.to_s), last_seen_at: Time.current) : nil)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Two requests from one browser made it at once: the other one won.
    Device.find_by(client_key: key) || raise
  end
end

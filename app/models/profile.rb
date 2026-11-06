# typed: strict
# frozen_string_literal: true

# Who is watching (PROPOSAL §4.4). Watch state belongs to a profile, not a
# login: one signed-in living-room browser, several people on it.
class Profile < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  has_many :watch_states, dependent: :delete_all
  has_many :playback_sessions, dependent: :delete_all
  has_many :playlists, dependent: :destroy
  has_many :channel_subscriptions, dependent: :delete_all

  has_secure_password :pin, validations: false
  has_many :profile_tags, dependent: :delete_all
  has_many :profile_exclusions, dependent: :delete_all
  has_many :station_hides, dependent: :delete_all
  has_many :station_favorites, dependent: :delete_all
  has_many :airing_reminders, dependent: :delete_all
  has_one :trakt_account, dependent: :delete

  class Kind < T::Enum
    include ApplicationEnum
    enums do
      Standard = new("standard")
      # No settings; meant for a rating ceiling or curated mode.
      Kid = new("kid")
    end
  end

  attribute :kind, Kind

  validates :max_rating_age, inclusion: { in: ContentRatings::CEILINGS }, allow_nil: true
  validates :up_next_seconds, numericality: { in: 0..60 }, allow_nil: true
  validates :still_watching_after, numericality: { in: 0..20 }, allow_nil: true

  sig { returns(T::Boolean) }
  def kid? = kind_enum == Kind::Kid

  # Anything narrower than the whole household's catalog.
  sig { returns(T::Boolean) }
  def restricted? = curated || !max_rating_age.nil? || library_ids.any?

  # Whether anything is hidden from this profile; asked once per instance,
  # since Viewing::Access asks on every catalog query of a request.
  sig { returns(T::Boolean) }
  def excludes_anything?
    @excludes_anything = T.let(@excludes_anything, T.nilable(T::Boolean))
    @excludes_anything = profile_exclusions.exists? if @excludes_anything.nil?
    @excludes_anything
  end

  validates :name, presence: true, length: { maximum: 40 }, uniqueness: { scope: :household_id }
  validates :pin, format: { with: /\A\d{4,8}\z/, message: "must be 4 to 8 digits" }, allow_nil: true
  validates :avatar, length: { maximum: 16 }, allow_nil: true
  before_save { self.pin_changed_at = Time.current if will_save_change_to_pin_digest? }

  sig { returns(T::Boolean) }
  def pin? = pin_digest.present?

  # Sets or (with nil) clears the PIN.
  sig { params(value: T.nilable(String)).void }
  def change_pin(value)
    if value.blank?
      self.pin_digest = nil
    else
      self.pin = value
    end
  end
  validates :color, format: { with: /\A#\h{6}\z/ }

  # Who a request watches as when it hasn't chosen: the first profile
  # without a PIN, so a PIN is never bypassed by just not asking.
  sig { params(household: Household).returns(Profile) }
  def self.open_default_for(household)
    unscoped.where(household_id: household.id, pin_digest: nil).order(:position, :created_at).first || default_for(household)
  end

  # Every household has one, made the first time anyone watches.
  sig { params(household: Household).returns(Profile) }
  def self.default_for(household)
    unscoped.where(household_id: household.id).order(:position, :created_at).first ||
      unscoped.create!(household_id: household.id, name: household.name.presence || "Everyone")
  rescue ActiveRecord::RecordNotUnique
    T.must(unscoped.where(household_id: household.id).order(:position, :created_at).first)
  end
end

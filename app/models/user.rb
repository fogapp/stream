# typed: strict
# frozen_string_literal: true

class User < ApplicationRecord
  extend T::Sig

  # Roles follow hub: admins own household infrastructure (libraries,
  # integrations, invites, the playback-decisions page); members watch,
  # subscribe and curate; guests are read-only.
  class Role < T::Enum
    include ApplicationEnum
    enums do
      Admin = new("admin")
      Member = new("member")
      Guest = new("guest")
    end
  end

  belongs_to :household
  has_many :api_sessions, dependent: :destroy
  has_many :api_tokens, dependent: :destroy
  has_many :webauthn_credentials, dependent: :destroy
  # Sign-ins from an OpenID provider linked to this account (fog sign-in).
  has_many :identities, dependent: :destroy
  has_many :notifications, dependent: :destroy

  has_secure_password

  attribute :role, Role

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, uniqueness: true,
    format: { with: URI::MailTo::EMAIL_REGEXP, message: "must be a valid email address" }
  validates :name, presence: true
  validates :password, length: { minimum: 10 }, allow_nil: true
  # A visitor (fog:docs/signin-proposal.md §10.4) is a guest of the
  # household, never its admin, however the role came to be asked for.
  validate :visitor_is_not_admin

  # The household's own people: visitors from paired households are not.
  scope :household_members, -> { where(visitor_home: nil) }

  sig { returns(T::Boolean) }
  def admin?
    role_enum == Role::Admin
  end

  sig { returns(T::Boolean) }
  def guest?
    role_enum == Role::Guest
  end

  # Signed in by a paired household's fog; visitor_home names it.
  sig { returns(T::Boolean) }
  def visitor?
    visitor_home.present?
  end

  private

  sig { void }
  def visitor_is_not_admin
    errors.add(:role, "can't be admin for a visitor") if visitor? && admin?
  end
end

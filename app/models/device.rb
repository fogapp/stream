# typed: strict
# frozen_string_literal: true

# A browser (later a TV) that plays, with the capability profile it last
# reported (PROPOSAL §4.4, §6.1). The transcode report asks every device
# seen lately what it would need.
class Device < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  has_many :playback_sessions, dependent: :nullify
  # Loads straight into this profile, no picker (PROPOSAL §7.4).
  belongs_to :default_profile, class_name: "Profile", optional: true

  validates :client_key, presence: true, length: { maximum: 64 }, uniqueness: { scope: :household_id }
  validates :name, presence: true

  scope :recent, -> { where(last_seen_at: 30.days.ago..) }
  # Can be played to right now: it lets itself be, and it's listening.
  scope :listening, -> { where(remote_control: true, remote_seen_at: LISTENING.ago..) }

  has_many :device_commands, dependent: :delete_all

  # A device that asked for commands this recently is on.
  LISTENING = T.let(20.seconds, ActiveSupport::Duration)

  sig { returns(String) }
  def display_name = label.presence || name

  sig { returns(T::Boolean) }
  def listening? = remote_control && !remote_seen_at.nil? && T.must(remote_seen_at) > LISTENING.ago

  sig { returns(Playback::Capabilities) }
  def capability_profile = Playback::Capabilities.from_json(capabilities)

  # "Safari on macOS", "Chrome on Windows" — enough to tell devices apart
  # on the admin page.
  sig { params(user_agent: String).returns(String) }
  def self.name_from(user_agent)
    # The Apple TV app says who it is (clients/appletv).
    return "Apple TV app" if user_agent.start_with?("StreamTV/")

    browser =
      if user_agent.include?("Edg/") then "Edge"
      elsif user_agent.include?("Firefox/") then "Firefox"
      elsif user_agent.include?("Chrome/") || user_agent.include?("CriOS/") then "Chrome"
      elsif user_agent.include?("Safari/") then "Safari"
      else "Browser"
      end
    platform =
      if user_agent.match?(/iPhone|iPad/) then "iOS"
      elsif user_agent.include?("Mac OS X") then "macOS"
      elsif user_agent.include?("Windows") then "Windows"
      elsif user_agent.include?("Android") then "Android"
      elsif user_agent.include?("Linux") then "Linux"
      end
    platform ? "#{browser} on #{platform}" : browser
  end
end

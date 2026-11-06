# typed: strict
# frozen_string_literal: true

# A device and what it decodes. The profile is the parsed one, so a device
# that reported little still answers with the conservative baseline.
module DeviceSerializer
  extend T::Sig

  sig { params(device: Device).returns(T::Hash[Symbol, T.untyped]) }
  def self.capabilities_json(device)
    { id: device.id, name: device.display_name, last_seen_at: device.last_seen_at.iso8601,
      capabilities: device.capability_profile.to_json_hash }
  end

  # A screen that can be played to (PROPOSAL §11 Phase 6), and what it's
  # playing.
  sig { params(device: Device).returns(T::Hash[Symbol, T.untyped]) }
  def self.remote_json(device)
    playing = Remote::Control.now_playing(device)
    { id: device.id, name: device.display_name, browser: device.name, label: device.label, remote_control: device.remote_control,
      listening: device.listening?,
      now_playing: playing && PlaybackSessionSerializer.heading(playing.playable).slice(:title, :subtitle) }
  end
end

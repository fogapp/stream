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
  sig { params(device: Device, playing: T.nilable(PlaybackSession), known: T::Boolean).returns(T::Hash[Symbol, T.untyped]) }
  def self.remote_json(device, playing: nil, known: false)
    playing = Remote::Control.now_playing(device) unless known
    { id: device.id, name: device.display_name, browser: device.name, label: device.label, remote_control: device.remote_control,
      listening: device.listening?,
      now_playing: playing && PlaybackSessionSerializer.heading(playing.playable).slice(:title, :subtitle) }
  end

  # Several screens, with what each is playing read at once.
  sig { params(devices: T::Array[Device]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.remote_index(devices)
    playing = Remote::Control.now_playing_on(devices)
    devices.map { |device| remote_json(device, playing: playing[device.id], known: true) }
  end
end

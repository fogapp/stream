# typed: strict
# frozen_string_literal: true

module Playback
  # Where a client says it can and can't:
  # known cases of a browser claiming a codec it then fails on, reviewed in
  # code rather than learned. Seeded from jellyfin-web's own notes
  # (browserDeviceProfile.js); what a household's devices teach on top of
  # these is learned per file and format (R3).
  module Quirks
    extend T::Sig

    class Quirk < T::Struct
      # Matched against the device's name (Device.name_from): "Safari on macOS".
      const :device, Regexp
      const :video, T::Array[String], default: []
      const :audio, T::Array[String], default: []
      const :hdr, T::Array[String], default: []
      const :why, String
    end

    LIST = T.let([
      Quirk.new(device: /\ASafari\b/, video: %w[h264_10],
        why: "Safari says yes to 10-bit H.264, then fails to play it (jellyfin-web)"),
      Quirk.new(device: /\AFirefox\b/, hdr: %w[hdr10 hdr10_plus hlg dolby_vision],
        why: "Firefox matches an HDR screen but shows HDR10 washed out")
    ].freeze, T::Array[Quirk])

    # The capabilities with every quirk of this device taken away.
    sig { params(capabilities: Capabilities, device_name: T.nilable(String)).returns(Capabilities) }
    def self.apply(capabilities, device_name)
      name = device_name.to_s
      LIST.select { |quirk| quirk.device.match?(name) }.reduce(capabilities) do |caps, quirk|
        caps.without(video: quirk.video, audio: quirk.audio, hdr: quirk.hdr)
      end
    end
  end
end

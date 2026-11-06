# typed: strict
# frozen_string_literal: true

# A transcoder process's last word that it's alive (Playback::TranscoderHeartbeat).
# Instance-wide, like the transcoder itself.
class TranscoderBeat < ApplicationRecord
  extend T::Sig
end

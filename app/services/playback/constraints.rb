# typed: strict
# frozen_string_literal: true

module Playback
  # What a fallback rules out: the rungs
  # of the ladder a play has already failed on, so the decision picks the
  # next one down. Kept on the session's decision, so a second fallback
  # builds on the first.
  class Constraints < T::Struct
    extend T::Sig

    # The original file, as the browser opens it.
    const :no_direct, T::Boolean, default: false
    # The file's optimized version.
    const :no_optimized, T::Boolean, default: false
    # The sound converted to stereo AAC, however well it might copy.
    const :convert_audio, T::Boolean, default: false
    # The picture converted to H.264, however well it might copy.
    const :convert_video, T::Boolean, default: false
    # Converted on this machine's CPU: a hardware encoder (or the node that
    # has one) failed.
    const :software, T::Boolean, default: false

    NONE = T.let(new, Constraints)

    sig { params(raw: T.untyped).returns(Constraints) }
    def self.from_h(raw)
      return NONE unless raw.is_a?(Hash)

      new(**props.keys.to_h { |name| [ name, raw[name.to_s] == true ] })
    end

    sig { returns(T::Hash[String, T::Boolean]) }
    def to_h = serialize.select { |_, value| value == true }

    sig { returns(T::Boolean) }
    def none? = to_h.empty?

    sig { params(changes: T::Boolean).returns(Constraints) }
    def with(**changes) = Constraints.new(**serialize.symbolize_keys, **changes)

    # Both sets of rungs ruled out.
    sig { params(other: Constraints).returns(Constraints) }
    def |(other) = Constraints.new(**serialize.symbolize_keys.to_h { |name, value| [ name, value || other.serialize[name.to_s] == true ] })
  end
end

# typed: strict
# frozen_string_literal: true

module EpisodeIdentitySerializer
  extend T::Sig

  sig { params(result: Markers::Identity::Result).returns(T::Hash[Symbol, T.untyped]) }
  def self.json(result)
    { intro: result.intro, confidence: result.confidence, compared: result.compared }
  end
end

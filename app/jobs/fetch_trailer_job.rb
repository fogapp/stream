# typed: strict
# frozen_string_literal: true

# Fetches one trailer (Youtube::TrailerFetch). One at a time; a failure is
# kept on the trailer and tried again later.
class FetchTrailerJob < ApplicationJob
  extend T::Sig

  queue_as :sync
  limits_concurrency to: 1, key: "trailers", duration: 30.minutes

  sig { params(trailer_id: String).void }
  def perform(trailer_id)
    trailer = Trailer.unscoped.find_by(id: trailer_id)
    return if trailer.nil? || trailer.state_enum == Trailer::State::Ready || trailer.attempts >= Trailer::MAX_ATTEMPTS

    Youtube::TrailerFetch.new(trailer).call
  end
end

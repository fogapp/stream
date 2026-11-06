# typed: strict
# frozen_string_literal: true

module Stations
  # Something a channel could air: a film, an episode or a YouTube video
  # with a readable file and its real length (the probe's, not TMDB's
  # runtime).
  class Candidate < T::Struct
    const :playable_type, String
    const :playable_id, String
    const :media_file_id, String
    const :duration, Float
    # What a cursor follows: the show for an episode, the channel for a
    # video, "movies" for a film.
    const :series_key, String
    const :series_title, String
    const :season, Integer, default: 0
    const :episode, Integer, default: 0
    const :aired_on, T.nilable(Date)
  end
end

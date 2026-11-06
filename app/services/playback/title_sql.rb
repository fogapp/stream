# typed: strict
# frozen_string_literal: true

module Playback
  # A playable's name in SQL, whatever it is — a film, an episode, a
  # YouTube video, an extra, a live stream — falling back to the file's path, for the
  # Playback page's tables to search and sort by.
  module TitleSql
    extend T::Sig

    TITLE = "COALESCE(movies.title, shows.title || ' ' || episodes.title, videos.title, extras.title, live_streams.name, media_files.path)"

    # The joins TITLE reads, given the columns holding the playable's type
    # and id (media_files is joined by the caller).
    sig { params(type: String, id: String).returns(T::Array[String]) }
    def self.joins(type, id)
      [
        "LEFT JOIN movies ON #{type} = 'Movie' AND movies.id = #{id}",
        "LEFT JOIN episodes ON #{type} = 'Episode' AND episodes.id = #{id}",
        "LEFT JOIN shows ON shows.id = episodes.show_id",
        "LEFT JOIN videos ON #{type} = 'Video' AND videos.id = #{id}",
        "LEFT JOIN extras ON #{type} = 'Extra' AND extras.id = #{id}",
        "LEFT JOIN live_streams ON #{type} = 'LiveStream' AND live_streams.id = #{id}"
      ]
    end
  end
end

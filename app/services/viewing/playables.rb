# typed: strict
# frozen_string_literal: true

module Viewing
  # A title a client names by type and id ("movie", "…"): found in the
  # household and only if this profile may see it, or not found at all.
  module Playables
    extend T::Sig

    Playable = T.type_alias { T.any(Movie, Show, Episode, Extra, Video, Clip, LiveStream) }

    sig { params(type: T.untyped, id: T.untyped, only: T::Array[String]).returns(Playable) }
    def self.find!(type, id, only:)
      type = type.to_s
      raise ActiveRecord::RecordNotFound unless only.include?(type)

      id = id.to_s
      found =
        case type
        when "movie" then Movie.find(id)
        when "show" then Show.find(id)
        when "episode" then Episode.joins(:show).merge(Show.all).find(id)
        when "extra" then Extra.find(id)
        when "video" then Video.find(id)
        when "clip" then Clip.find(id)
        when "live_stream" then LiveStream.find(id)
        else raise ActiveRecord::RecordNotFound
        end
      raise ActiveRecord::RecordNotFound unless Access.allows?(found)

      found
    end
  end
end

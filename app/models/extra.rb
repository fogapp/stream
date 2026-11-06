# typed: strict
# frozen_string_literal: true

# A trailer, featurette, deleted scene… (PROPOSAL §4.2): one file, found by
# Plex's and Jellyfin's naming conventions, played like any title but never
# in Continue watching.
class Extra < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  class Kind < T::Enum
    include ApplicationEnum
    enums do
      Trailer = new("trailer")
      Featurette = new("featurette")
      BehindTheScenes = new("behind_the_scenes")
      DeletedScene = new("deleted_scene")
      Interview = new("interview")
      Scene = new("scene")
      Short = new("short")
      Other = new("other")
    end
  end

  belongs_to :media_file
  belongs_to :owner, polymorphic: true, optional: true

  attribute :kind, Kind

  validates :title, presence: true

  # Trailers first, then the rest in a stable order.
  ORDER = T.let(Kind.values.map(&:serialize).freeze, T::Array[String])

  # The playback surface asks every playable for its files.
  sig { returns(T.untyped) }
  def media_files
    MediaFile.where(id: media_file_id)
  end

  sig { returns(String) }
  def kind_label
    case kind_enum
    when Kind::Trailer then "Trailer"
    when Kind::Featurette then "Featurette"
    when Kind::BehindTheScenes then "Behind the scenes"
    when Kind::DeletedScene then "Deleted scene"
    when Kind::Interview then "Interview"
    when Kind::Scene then "Scene"
    when Kind::Short then "Short"
    else "Extra"
    end
  end
end

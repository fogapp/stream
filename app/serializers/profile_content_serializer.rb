# typed: strict
# frozen_string_literal: true

# The titles a profile's own configuration names (Settings › Profiles):
# what's hidden from it and what's tagged for it.
module ProfileContentSerializer
  extend T::Sig

  Item = T.type_alias { T.any(Movie, Show, Channel, Album) }

  sig { params(records: T::Array[Item]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.items(records)
    images = ArtworkSerializer.index(records)
    records.map { |record| item(record, images) }
  end

  sig { params(record: Item, images: ArtworkSerializer::Index).returns(T::Hash[Symbol, T.untyped]) }
  def self.item(record, images)
    pictures = ArtworkSerializer.images(images, record)
    case record
    when Movie then { kind: "movie", id: record.id, title: record.title, detail: record.year&.to_s, image: pictures["poster"] }
    when Show then { kind: "show", id: record.id, title: record.title, detail: record.year&.to_s, image: pictures["poster"] }
    when Channel then { kind: "channel", id: record.id, title: record.title, detail: record.handle, image: pictures["profile"] }
    when Album then { kind: "album", id: record.id, title: record.title, detail: nil, image: nil }
    else T.absurd(record)
    end
  end
end

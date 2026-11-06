# typed: strict
# frozen_string_literal: true

module Artworks
  # A named face's thumbnail from Immich (PROPOSAL §5.4), for the people
  # filter on the home-video timeline.
  module ImmichFaces
    extend T::Sig

    sig { params(person: HomePerson).void }
    def self.sync(person)
      setting = ImmichSetting.unscoped.find_by(household_id: person.household_id)
      return if setting.nil?

      artwork = Artwork.find_or_initialize_by(owner: person, kind: Artwork::Kind::Profile.serialize)
      return if artwork.ready? || artwork.given_up?

      artwork.update!(source: Artwork::Source::Immich.serialize, source_ref: person.immich_id)
      Tempfile.create([ "face", ".jpg" ]) do |file|
        Immich::Client.new(setting).person_thumbnail(person.immich_id, into: Pathname.new(file.path))
        Publish.call(artwork, source: file.path)
      end
    rescue UpstreamHttpClient::Error, Renderer::Error, ToolRunner::Error => e
      artwork&.record_failure!(e)
    end
  end
end

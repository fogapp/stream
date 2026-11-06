# typed: strict
# frozen_string_literal: true

module Artworks
  # Renders a source into a new version of an artwork and swaps it in: the
  # new files land under version+1 before the row points at them, so a
  # request never sees a half-written image, and the old version is removed
  # only after.
  module Publish
    extend T::Sig

    sig { params(artwork: Artwork, source: String, alpha: T::Boolean, seek_seconds: T.nilable(Float)).void }
    def self.call(artwork, source:, alpha: false, seek_seconds: nil)
      kind = artwork.kind_enum
      next_version = artwork.version + 1
      target = artwork.directory.join(next_version.to_s)
      result = Renderer.render(source, into: target, widths: kind.widths, alpha: alpha, seek_seconds: seek_seconds)
      previous = artwork.directory.join(artwork.version.to_s)
      artwork.update!(version: next_version, state: Artwork::State::Ready.serialize, width: result.width,
        height: result.height, rendered_widths: result.widths, placeholder: result.placeholder, color: result.color,
        last_error: nil, consecutive_failures: 0)
      FileUtils.rm_rf(previous) if previous != target
    rescue StandardError
      FileUtils.rm_rf(target) if target
      raise
    end
  end
end

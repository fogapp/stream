# typed: strict
# frozen_string_literal: true

# What the web app polls to learn that the catalog moved — a file became
# playable, was replaced, or went missing — so it refreshes Home, search and
# the library pages without a reload. Opaque: only a change means anything.
module CatalogVersionSerializer
  extend T::Sig

  sig { params(version: String).returns(T::Hash[Symbol, String]) }
  def self.json(version)
    { version: version }
  end
end

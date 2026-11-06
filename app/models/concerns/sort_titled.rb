# typed: strict
# frozen_string_literal: true

# "The Matrix" sorts under M. Clips and live streams don't use this: an
# article in what's on a camera or in a filename is part of how it sorts.
module SortTitled
  extend ActiveSupport::Concern
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ApplicationRecord }

  included do
    T.bind(self, T.class_of(ApplicationRecord))

    before_validation :derive_sort_title
  end

  private

  sig { void }
  def derive_sort_title
    T.unsafe(self).sort_title = T.unsafe(self).title.to_s.sub(/\A(the|a|an)\s+/i, "").downcase
  end
end

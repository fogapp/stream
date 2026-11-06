# typed: strict
# frozen_string_literal: true

class CollectionItem < ApplicationRecord
  extend T::Sig

  belongs_to :collection
  belongs_to :item, polymorphic: true
end

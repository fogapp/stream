# typed: strict
# frozen_string_literal: true

class Credit < ApplicationRecord
  extend T::Sig

  class Role < T::Enum
    include ApplicationEnum
    enums do
      Cast = new("cast")
      Director = new("director")
      Writer = new("writer")
      Creator = new("creator")
    end
  end

  belongs_to :person
  belongs_to :creditable, polymorphic: true

  attribute :role, Role
end

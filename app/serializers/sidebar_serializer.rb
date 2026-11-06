# typed: strict
# frozen_string_literal: true

# A profile's sidebar: the keys it has placed, in order, and the ones it hid.
module SidebarSerializer
  extend T::Sig

  sig { params(profile: Profile).returns(T::Hash[Symbol, T::Array[String]]) }
  def self.json(profile)
    { order: Array(profile.sidebar["order"]), hidden: Array(profile.sidebar["hidden"]) }
  end
end

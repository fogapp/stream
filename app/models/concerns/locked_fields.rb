# typed: strict
# frozen_string_literal: true

# Field locks (PROPOSAL §4.2): a field a person edited is named in
# locked_fields and no refresh writes it again — Plex's best idea.
module LockedFields
  extend T::Sig
  extend T::Helpers

  requires_ancestor { ApplicationRecord }

  # Assigns only the fields nobody has locked.
  sig { params(attributes: T::Hash[Symbol, T.untyped]).void }
  def assign_unlocked(attributes)
    locked = T.unsafe(self).locked_fields.to_set
    T.unsafe(self).assign_attributes(attributes.reject { |key, _| locked.include?(key.to_s) })
  end

  # Whether a person has locked this field.
  sig { params(field: T.any(String, Symbol)).returns(T::Boolean) }
  def locked?(field) = T.unsafe(self).locked_fields.include?(field.to_s)
end

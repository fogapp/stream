# typed: strict
# frozen_string_literal: true

# The household's TMDB connection (PROPOSAL §5.2). Entered in Settings,
# stored encrypted, never serialized back (CLAUDE.md › Configuration).
class TmdbSetting < ApplicationRecord
  extend T::Sig
  include HouseholdScoped
  include ConnectionTested

  encrypts :api_key

  sig { returns(T::Boolean) }
  def configured? = api_key.present?
end

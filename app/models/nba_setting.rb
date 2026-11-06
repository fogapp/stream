# typed: strict
# frozen_string_literal: true

# NBA League Pass (PROPOSAL §7.8): the household watches on NBA.com.
# Turning it on is what puts Basketball in the sidebar. It keeps no
# account: League Pass games are DRM-protected, so Stream can't play them,
# and a game opens on NBA.com, where the person signs in.
class NbaSetting < ApplicationRecord
  extend T::Sig
  include HouseholdScoped
  include ConnectionTested
end

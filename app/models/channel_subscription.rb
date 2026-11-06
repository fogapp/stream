# typed: strict
# frozen_string_literal: true

# A profile following a channel's new videos (PROPOSAL §5.4) — not the
# admin's "follow on YouTube", which is about downloading.
class ChannelSubscription < ApplicationRecord
  extend T::Sig

  belongs_to :profile
  belongs_to :channel
end

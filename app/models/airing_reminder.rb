# typed: strict
# frozen_string_literal: true

# "Remind me" on a program in the guide (PROPOSAL §7.7): told a couple of
# minutes before it starts, in the app and on the profile's ntfy topic. A
# rebuilt schedule takes its reminders with the airings it drops.
class AiringReminder < ApplicationRecord
  extend T::Sig

  BEFORE = T.let(2.minutes, ActiveSupport::Duration)

  belongs_to :profile
  belongs_to :user
  belongs_to :airing
end

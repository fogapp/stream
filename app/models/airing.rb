# typed: strict
# frozen_string_literal: true

# One program on a channel's schedule (PROPOSAL §7.7): this file, from then
# to then, and why it was chosen. Fixed once written — only editing the
# channel rebuilds what hasn't started — except a game (mlb_game_pk), which
# has no file: it plays a team's stream, and its end follows the game
# (Stations::Games).
class Airing < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  belongs_to :station
  belongs_to :station_block, optional: true
  belongs_to :playable, polymorphic: true
  belongs_to :media_file, optional: true
  has_many :airing_reminders, dependent: :delete_all

  validates :starts_at, :ends_at, :reason, :series_key, presence: true

  sig { returns(T::Boolean) }
  def game? = !mlb_game_pk.nil?

  sig { returns(Float) }
  def duration = (ends_at - starts_at).to_f

  # How far into this airing a moment is.
  sig { params(time: ActiveSupport::TimeWithZone).returns(Float) }
  def offset_at(time = Time.current) = (time - starts_at).to_f.clamp(0.0, [ duration - 1.0, 0.0 ].max)

  # Where someone tuning in then joins it, in seconds into the file: a part
  # of a program broken for breaks starts partway in.
  sig { params(time: ActiveSupport::TimeWithZone).returns(Float) }
  def position_at(time = Time.current) = media_start + offset_at(time)

  # What airs after this on its channel: back to back, or after a gap.
  # Asked of the schedule as it is now, so an edit that rebuilt what hadn't
  # started yet still has an answer.
  sig { returns(T.nilable(Airing)) }
  def following
    Airing.unscoped.where(station_id: station_id).where(starts_at: (ends_at - 1.second)..).where.not(id: id).order(:starts_at).first
  end

  # The other parts of the same program, this one among them, first first.
  sig { returns(T::Array[Airing]) }
  def parts
    return [ self ] if media_start.zero? && media_end.nil?

    # Its breaks together are shorter than the grid's hour: the parts are
    # within the program's length and an hour either side.
    length = media_file&.duration_seconds.to_f
    window = (starts_at - media_start.seconds - 1.hour)..(ends_at + (length - media_start).seconds + 1.hour)
    Airing.unscoped.where(station_id: station_id, playable_type: playable_type, playable_id: playable_id, starts_at: window)
      .order(:starts_at).to_a
  end
end

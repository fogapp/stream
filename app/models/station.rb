# typed: strict
# frozen_string_literal: true

# A Grid channel (PROPOSAL §7.7): a number and a name, programmed by its
# blocks and airing what the scheduler fixed for the next three days. Called
# a station in code because YouTube's channels already own `Channel`.
class Station < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  # Between programs (PROPOSAL §7.7).
  class Filler < T::Enum
    include ApplicationEnum
    enums do
      # What's next, and a countdown.
      Slate = new("slate")
      # The library's trailers, featurettes and shorts.
      Extras = new("extras")
      # Videos from chosen YouTube channels: old adverts, idents, shorts.
      Videos = new("videos")
    end
  end

  NUMBER = /\A(\d{1,4})(?:\.(\d{1,2}))?\z/
  SNAPS = T.let([ 0, 5, 15, 30, 60 ].freeze, T::Array[Integer])
  # How far ahead the schedule is fixed.
  HORIZON = T.let(3.days, ActiveSupport::Duration)

  attribute :filler, Filler

  # Shows a camera or web stream instead of programming (PROPOSAL §7.8).
  # mlb_team_ids: clubs whose games air on it whenever they play, over its
  # programming (Stations::Games), the first listed first.
  belongs_to :live_stream, optional: true
  has_many :station_blocks, -> { order(:position, :created_at) }, dependent: :delete_all, inverse_of: :station
  has_many :airings, dependent: :delete_all
  has_many :station_hides, dependent: :delete_all
  has_many :station_favorites, dependent: :delete_all

  validates :name, presence: true, length: { maximum: 100 }
  validates :call_sign, length: { maximum: 8 }
  validates :number, format: { with: NUMBER, message: "is a channel number like 4 or 4.1" }
  validates :number, uniqueness: { scope: :household_id, message: "is already another channel's" }
  validates :snap_minutes, inclusion: { in: SNAPS }
  validates :no_repeat_days, numericality: { only_integer: true, in: 0..30 }
  validates :mlb_team_ids, length: { maximum: 30, message: "can be thirty teams at most" }
  validate :live_stream_is_this_households
  validate :games_or_a_stream

  before_validation do
    self.mlb_team_ids = Array(mlb_team_ids).map(&:to_i).select(&:positive?).uniq
    self.number = number.to_s.strip
    match = NUMBER.match(number)
    if match
      self.number_major = match[1].to_i
      self.number_minor = match[2].to_i
    end
  end

  scope :in_order, -> { order(:number_major, :number_minor) }

  # A stream's channel has no schedule: the stream is what's on.
  sig { returns(T::Boolean) }
  def streams? = !live_stream_id.nil?

  # What's on at this moment, if anything (a gap is a slate).
  # Its programming, replaced by these blocks in this order.
  sig { params(blocks: T::Array[T::Hash[Symbol, T.untyped]]).returns(T::Array[StationBlock]) }
  def replace_blocks!(blocks)
    station_blocks.delete_all
    blocks.each_with_index.map { |block, index| station_blocks.create!(block.merge(position: index)) }
  end

  sig { params(time: ActiveSupport::TimeWithZone).returns(T.nilable(Airing)) }
  def airing_at(time = Time.current)
    airings.where(starts_at: ..time).where("ends_at > ?", time).first
  end

  private

  sig { void }
  def games_or_a_stream
    errors.add(:base, "A channel showing a stream can't also carry games") if streams? && mlb_team_ids.any?
  end

  sig { void }
  def live_stream_is_this_households
    stream = live_stream
    errors.add(:live_stream, "isn't one of this household's") if stream && stream.household_id != household_id
  end
end

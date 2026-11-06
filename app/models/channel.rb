# typed: strict
# frozen_string_literal: true

# A YouTube channel, or any folder of videos by one maker (PROPOSAL §5.4).
class Channel < ApplicationRecord
  extend T::Sig
  include HouseholdScoped
  include LockedFields
  include SortTitled

  belongs_to :library
  has_many :videos, dependent: :destroy
  has_many :youtube_downloads, dependent: :delete_all
  has_many :channel_subscriptions, dependent: :delete_all

  class Backfill < T::Enum
    include ApplicationEnum
    enums do
      Recent = new("recent")
      All = new("all")
      Since = new("since")
    end
  end

  attribute :backfill, Backfill

  validates :backfill_count, numericality: { in: 1..5000 }
  validates :keep_last, numericality: { in: 1..5000 }, allow_nil: true
  validates :max_height, inclusion: { in: [ 360, 480, 720, 1080, 1440, 2160 ] }
  validates :poll_every_hours, numericality: { in: 1..168 }
  validates :backfill_since, presence: true, if: :backfill_by_date?
  validates :title_filter, length: { maximum: 500 }
  validate :title_filter_compiles
  before_validation { self.title_filter = title_filter.presence }

  # How long one title may take to match: a pattern that backtracks
  # without end gives up instead of holding the poll.
  TITLE_FILTER_TIMEOUT = 0.1

  # Whether the title filter lets this video through: any title when
  # there's no filter, one that matches (ignoring case) when there is. A
  # match that runs out of time doesn't.
  sig { params(title: T.nilable(String)).returns(T::Boolean) }
  def wants_title?(title)
    pattern = title_pattern
    pattern.nil? || pattern.match?(title.to_s)
  rescue Regexp::TimeoutError
    false
  end

  sig { returns(T::Boolean) }
  def backfill_by_date? = backfill_enum == Backfill::Since

  scope :due_for_poll, -> {
    where(tracked: true).where("last_polled_at IS NULL OR last_polled_at < now() - make_interval(hours => poll_every_hours)")
  }

  validates :title, presence: true

  private

  sig { returns(T.nilable(Regexp)) }
  def title_pattern
    source = title_filter
    source && Regexp.new(source, Regexp::IGNORECASE, timeout: TITLE_FILTER_TIMEOUT)
  end

  sig { void }
  def title_filter_compiles
    title_pattern
  rescue RegexpError => e
    errors.add(:title_filter, "isn't a pattern: #{e.message}")
  end
end

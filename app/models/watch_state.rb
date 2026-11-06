# typed: strict
# frozen_string_literal: true

# How far one profile got through one movie or episode (PROPOSAL §4.4).
class WatchState < ApplicationRecord
  extend T::Sig

  # Past this share of the running time, it counts as watched.
  COMPLETE_AT = 0.9
  # Under this, it was a peek, not a start: no resume point, no Continue
  # watching card.
  STARTED_AFTER = 120.0

  belongs_to :profile
  belongs_to :playable, polymorphic: true
  belongs_to :media_file, optional: true

  scope :in_progress, -> { where(completed_at: nil, hidden_from_continue: false).where("position_seconds > 0") }

  # What a profile has finished, of one kind or of everything.
  scope :finished, lambda { |profile, type = nil|
    done = where(profile: profile).where.not(completed_at: nil)
    type ? done.where(playable_type: type) : done
  }

  # Dismissed from Home. An episode takes its show off Next up too: that
  # card is the next episode, which usually has no state of its own yet,
  # so the show's latest one carries the flag, and Next up skips a show
  # whose latest state is hidden — until another episode is watched and
  # the report clears it.
  sig { params(profile: Profile, playable: T.any(Movie, Episode, Video, Clip)).void }
  def self.hide_from_home(profile, playable)
    ids = where(profile: profile, playable: playable).select(:id)
    if playable.is_a?(Episode)
      latest = where(profile: profile, playable_type: "Episode", playable_id: Episode.where(show_id: playable.show_id).select(:id))
        .order(Arel.sql("last_watched_at DESC NULLS LAST")).limit(1).select(:id)
      ids = where(id: ids).or(where(id: latest)).select(:id)
    end
    where(id: ids).update_all(hidden_from_continue: true) # rubocop:disable Rails/SkipsModelValidations
  end

  sig { returns(T::Boolean) }
  def completed? = !completed_at.nil?

  # Where to pick it up: nowhere once it's finished.
  sig { returns(T.nilable(Float)) }
  def resume_seconds = completed? ? nil : position_seconds

  # 0..1 of the way through, for progress bars.
  sig { returns(Float) }
  def progress
    duration = duration_seconds.to_f
    duration.positive? ? (position_seconds / duration).clamp(0.0, 1.0) : 0.0
  end
end

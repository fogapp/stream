# typed: strict
# frozen_string_literal: true

# A file's optimized version (PROPOSAL §5.5): an H.264 SDR MP4 with
# stereo AAC, encoded in quiet hours, which every browser plays as-is. The
# decision engine picks it when the original would need its video
# converted live. It lives on the cache volume: it can always be made again
# from the original, so it isn't backed up.
class OptimizedVersion < ApplicationRecord
  extend T::Sig
  include HouseholdScoped

  class State < T::Enum
    include ApplicationEnum
    enums do
      Queued = new("queued")
      Encoding = new("encoding")
      Ready = new("ready")
      Failed = new("failed")
      # An admin said not to make one: kept as a row so the hourly pass
      # never queues the file again, and never encoded.
      Skipped = new("skipped")
    end
  end

  class Origin < T::Enum
    include ApplicationEnum
    enums do
      # Asked for by an admin: encoded before anything automatic.
      Manual = new("manual")
      # Queued by the nightly pass, for a file no recent device plays
      # without converting.
      Automatic = new("automatic")
    end
  end

  # Why a version is in the queue: what the Playback page says beside it.
  class Reason < T::Enum
    include ApplicationEnum
    enums do
      Manual = new("manual")
      # No device seen this month plays the file without converting it.
      AllDevices = new("all_devices")
      # A Grid program airs it soon.
      Airing = new("airing")
      # The next episode of a show someone is watching.
      NextUp = new("next_up")
    end
  end

  # The order the transcoder takes queued versions in: the last one an
  # admin said to do next, then what admins asked for, then the soonest
  # needed (an airing tonight, the next episode), then the oldest.
  # Qualified, so it holds inside a query that joins other tables.
  QUEUE_ORDER_SQL = "optimized_versions.prioritized_at DESC NULLS LAST, " \
    "CASE WHEN optimized_versions.origin = 'manual' THEN 0 ELSE 1 END, optimized_versions.needed_at ASC NULLS LAST, " \
    "optimized_versions.created_at ASC, optimized_versions.id ASC"
  QUEUE_ORDER = T.let([ Arel.sql(QUEUE_ORDER_SQL) ].freeze, T::Array[Arel::Nodes::SqlLiteral])

  # Tried this many times, then left failed until someone asks again.
  MAX_ATTEMPTS = 3

  belongs_to :media_file

  attribute :state, State
  attribute :origin, Origin
  attribute :reason, Reason, allow_nil: true

  after_destroy_commit :remove_file

  scope :ready, -> { where(state: State::Ready.serialize) }
  scope :queued, -> { where(state: State::Queued.serialize) }
  scope :in_queue_order, -> { order(QUEUE_ORDER) }

  sig { returns(Pathname) }
  def self.root
    StreamPaths.cache.join("optimized")
  end

  # Bytes held by ready versions, against the budget in Settings.
  sig { returns(Integer) }
  def self.bytes_used = unscoped.ready.sum(:size).to_i

  # What may be encoded now, of a queue: outside quiet hours, or paused, only
  # what an admin asked for now; past the space budget only what an admin
  # asked for at all.
  sig { params(scope: T.untyped, setting: AppSetting, full: T::Boolean).returns(T.untyped) }
  def self.claimable(scope, setting, full:)
    scope = scope.where(run_now: true) if !setting.quiet_hours? || setting.optimize_paused
    scope = scope.where(origin: Origin::Manual.serialize) if full
    scope
  end

  # Where the encode writes before it's renamed into place.
  sig { params(id: String).returns(Pathname) }
  def self.partial_path_for(id) = root.join("#{id}.partial.mp4")

  sig { returns(Pathname) }
  def path = self.class.root.join("#{id}.mp4")

  sig { returns(Pathname) }
  def partial_path = self.class.partial_path_for(id.to_s)

  sig { returns(T::Boolean) }
  def ready? = state_enum == State::Ready && path.file?

  sig { params(origin: T.nilable(Origin), run_now: T::Boolean).void }
  def requeue!(origin: nil, run_now: false)
    origin ||= origin_enum
    update!(state: State::Queued.serialize, progress: 0, error: nil, attempts: 0, origin: origin.serialize,
      run_now: run_now, interruptions: 0, interrupted_at: nil, interruption: nil,
      reason: origin == Origin::Manual ? Reason::Manual.serialize : reason)
  end

  # Ahead of everything else queued, until an admin says the same of
  # another.
  sig { void }
  def prioritize!
    update!(prioritized_at: Time.current)
  end

  # Never made: the hourly pass leaves the file alone from now on. A
  # version already made is deleted with its file.
  sig { void }
  def skip!
    FileUtils.rm_f([ path, partial_path ])
    update!(state: State::Skipped.serialize, progress: 0, size: nil, error: nil, run_now: false, prioritized_at: nil)
  end

  # An encode stopped part way (a viewer needed the machine, quiet hours
  # ended, its transcoder went quiet): back in the queue, with why. Its
  # attempt is given back unless the stop may have been the encode's own
  # doing — a transcoder that died on it.
  sig { params(why: String, refund: T::Boolean).void }
  def interrupted!(why, refund: true)
    update!(state: State::Queued.serialize, progress: 0, worker: nil, attempts: refund ? [ attempts - 1, 0 ].max : attempts,
      interruptions: interruptions + 1, interrupted_at: Time.current, interruption: why)
  end

  private

  sig { void }
  def remove_file
    FileUtils.rm_f([ path, partial_path ])
  end
end

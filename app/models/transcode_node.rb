# typed: strict
# frozen_string_literal: true

# Another machine converting video for Stream (PROPOSAL §11 Phase 6): a
# Mac mini with VideoToolbox, say. It runs bin/stream-transcode-worker,
# which polls with this node's token for the ffmpeg runs the transcoder
# gave it. Instance-wide, like the transcoder itself; admins manage them.
class TranscodeNode < ApplicationRecord
  extend T::Sig

  PREFIX = "streamnode_"
  # A transcoder fog provides stands for a pool of machines, so its room
  # can pass a single worker's.
  FOG_MAX_SESSIONS = 64
  # A node that hasn't polled in this long is offline: nothing new goes to
  # it, and what it was running is taken back.
  ONLINE = T.let(15.seconds, ActiveSupport::Duration)

  class Generated < T::Struct
    const :node, TranscodeNode
    const :token, String
  end

  has_many :transcode_runs, dependent: :delete_all
  has_many :playback_sessions, dependent: :nullify

  validates :name, presence: true, length: { maximum: 80 }
  validates :max_sessions, numericality: { in: 1..8 }, unless: :fog?
  validates :max_sessions, numericality: { in: 0..FOG_MAX_SESSIONS }, if: :fog?

  scope :enabled, -> { where(enabled: true) }
  # Transcoders fog provides (fog-compute/1, FogComputeController): one per
  # pool of machines paired with fog, never a machine of its own.
  scope :fog, -> { where.not(fog_pool: nil) }
  scope :online, -> { enabled.where(last_seen_at: ONLINE.ago..) }

  sig { params(name: String).returns(Generated) }
  def self.generate(name:)
    token = "#{PREFIX}#{SecureRandom.hex(24)}"
    node = create!(name: name, token_digest: digest(token), token_prefix: token.first(PREFIX.length + 6))
    Generated.new(node: node, token: token)
  end

  # fog's transcoder for a pool: the one it introduced before, or a new
  # one. Its token is never handed out; fog authenticates as itself.
  sig { params(pool: String, name: String).returns(TranscodeNode) }
  def self.for_fog_pool(pool, name:)
    find_by(fog_pool: pool) || generate(name: name.first(80)).node.tap { |node| node.update!(fog_pool: pool, max_sessions: 0) }
  rescue ActiveRecord::RecordNotUnique
    find_by!(fog_pool: pool)
  end

  sig { returns(T::Boolean) }
  def fog? = fog_pool.present?

  # The room fog last said its pool has for Stream, per class; a worker
  # has none to say, so always room as far as this goes.
  sig { params(klass: String).returns(Integer) }
  def fog_free(klass)
    return FOG_MAX_SESSIONS unless fog?

    free = capabilities["free"]
    free.is_a?(Hash) ? free[klass].to_i : 0
  end

  sig { params(token: String).returns(String) }
  def self.digest(token) = Digest::SHA256.hexdigest(token)

  sig { params(token: T.nilable(String)).returns(T.nilable(TranscodeNode)) }
  def self.authenticate(token)
    return nil unless token&.start_with?(PREFIX)

    find_by(token_digest: digest(token))
  end

  sig { returns(T::Boolean) }
  def online? = enabled && !last_seen_at.nil? && T.must(last_seen_at) > ONLINE.ago

  sig { returns(Playback::Encoders::Kind) }
  def encoder_kind = Playback::Encoders::Kind.try_deserialize(encoder.to_s) || Playback::Encoders::Kind::Software

  # How this node encodes, from what its worker reported.
  sig { returns(Playback::Encoders::Profile) }
  def profile
    Playback::Encoders::Profile.new(kind: encoder_kind,
      tonemap_filter: Playback::Encoders.tonemap_for(Array(capabilities["filters"]).map(&:to_s)))
  end

  # Video conversions it's doing for viewers right now.
  sig { returns(Integer) }
  def live_video_sessions
    playback_sessions.converting_now.count
  end
end

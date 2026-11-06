# typed: strict
# frozen_string_literal: true

module Playback
  # Where a video conversion runs (PROPOSAL §11 Phase 6): here, or on a
  # remote transcoder with room. Hardware beats software, and this machine
  # wins a tie, since it reads the file without the network. Repackaging
  # and audio conversion always stay here: they cost almost nothing.
  module Placement
    extend T::Sig

    # nil means this machine.
    sig { returns(T.nilable(TranscodeNode)) }
    def self.node_for_video
      local_hardware = Encoders.kind.hardware?
      # Every node's conversions, and this machine's (nil), in one count.
      busy = PlaybackSession.unscoped.converting_now.group(:transcode_node_id).count
      load = ->(node) { busy.fetch(node.id, 0) }
      local_free = busy.fetch(nil, 0) < Encoders.cap
      # A fog transcoder also needs room fog says its pool has: other apps
      # share its machines.
      candidates = TranscodeNode.online.to_a.select { |node| load.call(node) < node.max_sessions && node.fog_free("interactive").positive? }
      hardware = candidates.select { |node| node.encoder_kind.hardware? }
      return nil if local_hardware && local_free
      return hardware.min_by(&load) if hardware.any?
      return nil if local_free

      candidates.min_by(&load)
    end

    # Conversions all transcoders together take at once.
    sig { returns(Integer) }
    def self.capacity = Encoders.cap + TranscodeNode.online.sum(:max_sessions).to_i

    # The tallest conversion anything online can keep up with.
    sig { returns(Integer) }
    def self.max_height
      heights = TranscodeNode.online.map { |node| Encoders.max_height_for(node.encoder_kind) }
      ([ Encoders.max_height ] + heights).max || Encoders.max_height
    end

    # An idle online node that encodes optimized versions, hardware first;
    # nil when there's none and this machine should.
    sig { returns(T.nilable(TranscodeNode)) }
    def self.node_for_optimize
      # A worker optimizes only when idle; a fog transcoder when its pool
      # has batch room, since fog stops batch work for a viewer by itself.
      idle = TranscodeNode.online.where(optimize: true).to_a.select do |node|
        next node.fog_free("batch").positive? if node.fog?

        node.live_video_sessions.zero? && !node.transcode_runs.live.where.not(optimized_version_id: nil).exists?
      end
      hardware = idle.select { |node| node.encoder_kind.hardware? }
      return hardware.first if hardware.any?
      return nil if Encoders.kind.hardware?

      idle.first
    end
  end
end

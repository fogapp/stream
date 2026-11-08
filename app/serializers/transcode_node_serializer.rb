# typed: strict
# frozen_string_literal: true

module TranscodeNodeSerializer
  extend T::Sig

  # Every node, with every node's live runs read at once (and what each
  # is of, an episode's show included), not a query a node and a run.
  sig { params(nodes: T::Array[TranscodeNode]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.index(nodes)
    runs = live_runs(TranscodeRun.where(transcode_node_id: nodes.map(&:id))).group_by(&:transcode_node_id)
    nodes.map { |node| json(node, runs: runs.fetch(node.id, [])) }
  end

  sig { params(scope: T.untyped).returns(T::Array[TranscodeRun]) }
  def self.live_runs(scope)
    scope.live.includes(playback_session: { playable: %i[show] }, optimized_version: :media_file).to_a
  end

  # Never the token: only its first characters, to tell nodes apart.
  sig { params(node: TranscodeNode, runs: T.nilable(T::Array[TranscodeRun])).returns(T::Hash[Symbol, T.untyped]) }
  def self.json(node, runs: nil)
    runs ||= live_runs(node.transcode_runs)
    {
      id: node.id, name: node.name, token_prefix: node.token_prefix, enabled: node.enabled, optimize: node.optimize,
      max_sessions: node.max_sessions, online: node.online?, last_seen_at: node.last_seen_at,
      encoder: node.encoder && node.encoder_kind, hostname: node.capabilities["hostname"], platform: node.capabilities["platform"],
      ffmpeg: node.capabilities["ffmpeg"], worker_version: node.capabilities["worker"],
      tone_mapping: node.profile.tonemap_name,
      # A transcoder fog provides: its pool, and the room fog last said it has.
      fog_pool: node.fog_pool, fog_free: node.fog? ? { interactive: node.fog_free("interactive"), batch: node.fog_free("batch") } : nil,
      runs: runs.map do |run|
        { id: run.id, kind: run.optimized_version_id ? "optimize" : "session", state: run.state_enum,
          title: run.playback_session ? Playback::Report.title_for(run.playback_session&.playable) : run.optimized_version&.media_file&.filename }
      end,
      created_at: node.created_at
    }
  end
end

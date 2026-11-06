# typed: strict
# frozen_string_literal: true

module OptimizedVersionSerializer
  extend T::Sig

  sig { params(version: OptimizedVersion).returns(T::Hash[Symbol, T.untyped]) }
  def self.json(version)
    {
      id: version.id, media_file_id: version.media_file_id, state: version.state_enum, origin: version.origin_enum,
      run_now: version.run_now, progress: version.progress, height: version.height, size: version.size,
      tonemapped: version.tonemapped, encoder: version.encoder, error: version.error, attempts: version.attempts,
      worker: version.worker, started_at: version.started_at, finished_at: version.finished_at, created_at: version.created_at,
      reason: version.reason_enum, needed_at: version.needed_at, prioritized_at: version.prioritized_at,
      interruptions: version.interruptions, interrupted_at: version.interrupted_at, interruption: version.interruption
    }
  end

  # A row of the Queue and Optimized tables (Playback::OptimizedQuery):
  # where it stands in line, whether it fits the budget, how long it took,
  # and whether the household has played it since.
  sig do
    params(version: OptimizedVersion, fit: T.nilable({ estimated_bytes: Integer, fits: T::Boolean }))
      .returns(T::Hash[Symbol, T.untyped])
  end
  def self.table_json(version, fit)
    row_json(version).merge(
      queue_position: version.read_attribute("queue_position"), encode_seconds: version.read_attribute("encode_seconds")&.to_f&.round,
      last_played_at: version.read_attribute("last_played_at"), plays_since: version.read_attribute("plays_since").to_i,
      estimated_bytes: fit&.dig(:estimated_bytes), fits_budget: fit ? fit[:fits] : nil
    )
  end

  # The Optimized versions list: each with what it's a version of.
  sig { params(version: OptimizedVersion).returns(T::Hash[Symbol, T.untyped]) }
  def self.row_json(version)
    file = version.media_file
    json(version).merge(filename: file&.filename, title: Playback::Report.title_for(file&.editions&.first&.playable))
  end
end

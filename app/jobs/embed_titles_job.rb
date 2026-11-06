# typed: strict
# frozen_string_literal: true

# Keeps every title's vector current (PROPOSAL §7.1), and every video's
# (§5.4): the ones never embedded and the ones whose details changed since,
# a batch at a time.
class EmbedTitlesJob < ApplicationJob
  extend T::Sig

  queue_as :analyze
  limits_concurrency to: 1, key: -> { "embed_titles" }, duration: 1.hour

  BATCH = 500

  sig { void }
  def perform
    [ Movie, Show, Video ].each do |model|
      stale = model.unscoped.where(embedded_at: nil).or(model.unscoped.where("embedded_at < updated_at")).limit(BATCH)
      stale = stale.includes(:credits) unless model == Video
      stale.each do |title|
        vector = Recommendations::Embedder.vector(title)
        title.update_columns(embedding: vector, embedded_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      end
    end
  end
end

# typed: strict
# frozen_string_literal: true

module Channels
  # What a finished video offers over its last frame (PROPOSAL §5.4): one
  # more from the same channel, and a few from other channels — what this
  # profile hasn't finished first. Off in Settings › YouTube, there's none.
  module EndScreen
    extend T::Sig

    OTHERS = 3

    # `more` and `related` are what the watch page already found: the
    # channel's newest (unfinished first), and the nearest by tags and words.
    sig do
      params(profile: Profile, video: Video, more: T::Array[Video], related: T::Array[Video])
        .returns(T.nilable(T::Hash[Symbol, T.untyped]))
    end
    def self.json(profile, video, more:, related:)
      return nil unless AppSetting.cached.youtube_end_screen

      finished = WatchState.finished(profile, "Video")
      done = finished.where(playable_id: (more + related).map(&:id)).pluck(:playable_id).to_set
      same = more.find { |candidate| !done.include?(candidate.id) } || more.first
      others = related.reject { |candidate| candidate.channel_id == video.channel_id }
        .sort_by { |candidate| done.include?(candidate.id) ? 1 : 0 }.first(OTHERS)
      # Nothing near enough yet (a new library, untagged videos): the newest
      # this profile hasn't finished, from anywhere else.
      if others.size < OTHERS
        others += Catalog.watchable_videos(Video.where.not(channel_id: video.channel_id).where.not(id: others.map(&:id)))
          .where.not(id: finished.select(:playable_id))
          .order(Arel.sql("upload_date DESC NULLS LAST, created_at DESC, id")).limit(OTHERS - others.size).includes(:channel).to_a
      end

      cards = Catalog.cards(profile, [ same, *others ].compact)
      { next: same && cards.first, others: same ? cards.drop(1) : cards }
    end
  end
end

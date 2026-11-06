# typed: strict
# frozen_string_literal: true

# What the palette shows of Hook (PROPOSAL §7.9): a search hit, and a show
# with each season counted against what Stream already plays. Hook's own
# shapes (hook:app/serializers) are read here and nowhere else.
module HookRequestSerializer
  extend T::Sig

  sig do
    params(kind: Hook::Requests::Kind, hit: T::Hash[String, T.untyped], held: T.nilable(T.any(Movie, Show)))
      .returns(T::Hash[Symbol, T.untyped])
  end
  def self.hit_json(kind, hit, held)
    {
      kind: kind.serialize, provider: hit["provider"].to_s, external_id: hit["external_id"].to_s,
      title: hit["title"].to_s, year: hit["year"], overview: hit["overview"], poster_url: hit["poster_url"],
      network: hit["network"],
      # In Stream, and this profile may see it: the palette opens it there.
      in_stream_id: held&.id,
      # Wanted in Hook already (a film); a show's seasons say for themselves.
      requested: Array(hit["want_ids"]).any?,
      hook_show_id: hit["show_id"]
    }
  end

  sig do
    params(show: T::Hash[String, T.untyped], held: T.nilable(Show), on_disk: T::Set[[ Integer, T.nilable(Integer) ]])
      .returns(T::Hash[Symbol, T.untyped])
  end
  def self.show_json(show, held, on_disk)
    following = show["following"]
    {
      hook_show_id: show["id"].to_s, title: show["title"].to_s, year: show["year"], poster_url: show["poster_url"],
      network: show["network"] || show["web_channel"], in_stream_id: held&.id,
      following: following.is_a?(Hash) ? following["describe"].to_s.presence || "Followed" : nil,
      seasons: seasons_json(Array(show["seasons"]), on_disk)
    }
  end

  # Specials last, as Stream's own season list has them.
  sig do
    params(seasons: T::Array[T.untyped], on_disk: T::Set[[ Integer, T.nilable(Integer) ]])
      .returns(T::Array[T::Hash[Symbol, T.untyped]])
  end
  def self.seasons_json(seasons, on_disk)
    rows = seasons.grep(Hash).map do |season|
      number = season["season_number"].to_i
      episodes = Array(season["episodes"]).grep(Hash)
      upcoming = episodes.reject { |episode| episode["aired"] }.filter_map { |episode| episode["air_date"].presence }.min
      {
        number: number, episodes: episodes.length, aired: episodes.count { |episode| episode["aired"] },
        in_stream: episodes.count { |episode| on_disk.include?([ number, episode["episode_number"] ]) },
        requested: episodes.count { |episode| Array(episode["wants"]).any? },
        next_air_date: upcoming
      }
    end
    rows.sort_by { |row| [ row[:number].zero? ? 1 : 0, row[:number] ] }
  end
  private_class_method :seasons_json
end

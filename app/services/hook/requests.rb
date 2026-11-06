# typed: strict
# frozen_string_literal: true

module Hook
  # Asking Hook for what Stream doesn't have yet (PROPOSAL §7.9): the
  # palette's second search. Hook's answers are laid over what the household
  # already holds, so a hit says whether it is in Stream for this profile
  # (Viewing::Access), a show's season how much of it is, and only what is
  # missing is asked for.
  module Requests
    extend T::Sig

    # What the palette searches for. Hook calls a show's kind `episode`.
    class Kind < T::Enum
      include ApplicationEnum

      enums do
        Movie = new("movie")
        Show = new("show")
      end
    end

    # What following a show keeps coming: only what airs from today, or
    # everything Hook's defaults allow (the back catalogue proposed in
    # Hook's inbox). Seasons already aired are asked for by number.
    class Follow < T::Enum
      include ApplicationEnum

      enums do
        Future = new("future")
        Everything = new("everything")
      end
    end

    sig { params(client: Client, kind: Kind, query: String).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.search(client, kind:, query:)
      hits = client.search(media_kind: hook_kind(kind), query: query)
      held = held_by_tmdb_id(kind, hits.filter_map { |hit| hit["tmdb_id"] })
      hits.map { |hit| HookRequestSerializer.hit_json(kind, hit, held[hit["tmdb_id"]]) }
    end

    sig { params(client: Client, provider: String, external_id: String).returns(T::Hash[String, T.untyped]) }
    def self.want_movie(client, provider:, external_id:)
      want = client.want_movie(provider: provider, external_id: external_id)
      Activity.record(source: "hook", event: "request.movie", summary: "#{asker} asked Hook for #{want['title'] || 'a film'}",
        payload: { provider: provider, external_id: external_id, want_id: want["id"] })
      want
    end

    # The show in Hook (added if it wasn't), each season against Stream.
    sig { params(client: Client, provider: String, external_id: String).returns(T::Hash[Symbol, T.untyped]) }
    def self.show(client, provider:, external_id:)
      detail(client.add_show(provider: provider, external_id: external_id))
    end

    # Each season wanted in Hook, then the follow, if asked for. A season
    # Hook refuses stops the rest, and what was already asked stays asked.
    sig do
      params(client: Client, show_id: String, season_numbers: T::Array[Integer], follow: T.nilable(Follow))
        .returns(T::Hash[Symbol, T.untyped])
    end
    def self.want_show(client, show_id:, season_numbers:, follow:)
      created = 0
      already = 0
      show = T.let(nil, T.nilable(T::Hash[String, T.untyped]))
      season_numbers.uniq.sort.each do |number|
        answer = client.want_season(show_id: show_id, season_number: number)
        created += answer["created"].to_i
        already += answer["already"].to_i
        show = answer["show"].is_a?(Hash) ? answer["show"] : show
      end
      show = client.follow(show_id: show_id, rule: preset_rule(client, follow)) if follow
      raise Client::Error, "Choose a season or follow the show" if show.nil?

      Activity.record(source: "hook", event: "request.show", summary: summary(show, season_numbers, follow),
        payload: { show_id: show_id, seasons: season_numbers, follow: follow&.serialize, created: created })
      { created: created, already: already, show: detail(show) }
    end

    sig { params(kind: Kind).returns(String) }
    def self.hook_kind(kind)
      case kind
      when Kind::Movie then "movie"
      when Kind::Show then "episode"
      else T.absurd(kind)
      end
    end
    private_class_method :hook_kind

    sig { params(kind: Kind, tmdb_ids: T::Array[T.untyped]).returns(T::Hash[Integer, T.any(::Movie, ::Show)]) }
    def self.held_by_tmdb_id(kind, tmdb_ids)
      return {} if tmdb_ids.empty?

      scope = case kind
      when Kind::Movie then Viewing::Access.movies(::Movie.all)
      when Kind::Show then Viewing::Access.shows(::Show.all)
      else T.absurd(kind)
      end
      scope.where(tmdb_id: tmdb_ids).index_by(&:tmdb_id)
    end
    private_class_method :held_by_tmdb_id

    # Hook's show, and which of its episodes Stream already plays: by
    # season and episode number, across every library the profile sees.
    sig { params(show: T::Hash[String, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
    def self.detail(show)
      held = show["tmdb_id"] ? Viewing::Access.shows(::Show.all).where(tmdb_id: show["tmdb_id"]).to_a : []
      on_disk = Episode.where(show_id: held.map(&:id)).joins(:media_files).merge(MediaFile.present)
        .distinct.pluck(:season_number, :episode_number).to_set
      HookRequestSerializer.show_json(show, held.first, on_disk)
    end
    private_class_method :detail

    sig { params(client: Client, follow: Follow).returns(T::Hash[String, T.untyped]) }
    def self.preset_rule(client, follow)
      key = case follow
      when Follow::Future then "new_releases"
      when Follow::Everything then "everything"
      else T.absurd(follow)
      end
      preset = client.follow_presets.find { |candidate| candidate["key"] == key }
      raise Client::Error, "Hook offers no #{key.humanize.downcase} follow" unless preset.is_a?(Hash) && preset["rule"].is_a?(Hash)

      preset["rule"]
    end
    private_class_method :preset_rule

    sig { params(show: T::Hash[String, T.untyped], season_numbers: T::Array[Integer], follow: T.nilable(Follow)).returns(String) }
    def self.summary(show, season_numbers, follow)
      seasons = season_numbers.uniq.sort.map { |number| number.zero? ? "the specials" : "season #{number}" }
      asked = [ seasons.to_sentence.presence, follow && (follow == Follow::Future ? "to follow its new episodes" : "to follow it") ].compact
      "#{asker} asked Hook for #{show['title'] || 'a show'}: #{asked.join(', and ')}"
    end
    private_class_method :summary

    sig { returns(String) }
    def self.asker
      user = Current.user
      user.is_a?(User) ? user.name : "Someone"
    end
    private_class_method :asker
  end
end

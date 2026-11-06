# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # The command palette's search (PROPOSAL §7.2).
    class SearchController < BaseController
      sig { void }
      def show
        found = Viewing::Search.call(params[:q].to_s)
        movies = found.fetch(:movies)
        shows = found.fetch(:shows)
        episodes = found.fetch(:episodes)
        people = found.fetch(:people)
        collections = found.fetch(:collections)
        channels = found.fetch(:channels)
        videos = found.fetch(:videos)
        clips = found.fetch(:clips)
        cards = Viewing::Cards.new(current_profile!).prime(movies + shows + episodes + videos + clips, pictured: people + collections + channels)
        render json: {
          movies: movies.map { |movie| cards.card(movie) },
          shows: shows.map { |show| cards.card(show) },
          episodes: episodes.map { |episode| cards.card(episode) },
          people: people.map { |person| { id: person.id, name: person.name, image: cards.images(person)["profile"] } },
          collections: collections.map { |c| { id: c.id, title: c.title, image: cards.images(c)["poster"] } },
          channels: channels.map { |c| { id: c.id, title: c.title, image: cards.images(c)["profile"] } },
          videos: videos.map { |video| cards.card(video) },
          said: found.fetch(:said).map { |hit| said_json(hit) },
          clips: clips.map { |clip| cards.card(clip) }
        }
      end

      private

      sig { params(hit: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
      def said_json(hit)
        playable = hit.fetch(:playable)
        title = case playable
        when Episode then [ playable.show&.title, playable.code ].compact.join(" ")
        else playable.title
        end
        { kind: playable.class.name.to_s.downcase, id: playable.id, title: title, start: hit.fetch(:start).floor, snippet: hit.fetch(:snippet) }
      end
    end
  end
end

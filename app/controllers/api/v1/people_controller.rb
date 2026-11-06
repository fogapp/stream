# typed: strict
# frozen_string_literal: true

module Api
  module V1
    # A person across every library (PROPOSAL §7.2): what they're in that
    # this household can watch.
    class PeopleController < BaseController
      finds :person, from: -> { Person.all }

      sig { void }
      def show
        credits = person.credits.where(creditable_type: %w[Movie Show]).to_a
        movie_ids = credits.select { |credit| credit.creditable_type == "Movie" }.map(&:creditable_id)
        show_ids = credits.select { |credit| credit.creditable_type == "Show" }.map(&:creditable_id)
        movies = Viewing::Catalog.watchable_movies(Movie.where(id: movie_ids)).order(year: :desc).to_a
        shows = Viewing::Catalog.watchable_shows(Show.where(id: show_ids)).order(year: :desc).to_a
        cards = Viewing::Cards.new(current_profile!).prime(movies + shows, pictured: [ person ])
        roles = credits.group_by(&:creditable_id)
        render json: {
          id: person.id, name: person.name, tmdb_id: person.tmdb_id, image: cards.images(person)["profile"],
          movies: movies.map { |movie| cards.card(movie).merge(credit: credit_label(roles[movie.id])) },
          shows: shows.map { |show| cards.card(show).merge(credit: credit_label(roles[show.id])) }
        }
      end

      private

      # "as Neil McCauley", or "Director", or both.
      sig { params(credits: T.nilable(T::Array[Credit])).returns(T.nilable(String)) }
      def credit_label(credits)
        return nil if credits.nil?

        credits.sort_by { |credit| credit.role_enum == Credit::Role::Cast ? 0 : 1 }.filter_map do |credit|
          if credit.role_enum == Credit::Role::Cast
            credit.character.present? ? "as #{credit.character}" : "Cast"
          else
            credit.job.presence || credit.role_enum.serialize.capitalize
          end
        end.uniq.join(" · ").presence
      end
    end
  end
end

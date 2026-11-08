# typed: strict
# frozen_string_literal: true

module Stations
  # What the channel editor offers to choose from (PROPOSAL §7.7): the
  # library's own genres, networks, studios and keywords (most titles
  # first), its shows and collections, YouTube channels, profiles, live
  # streams, MLB clubs and decades. The current household's, by the models'
  # own scope.
  module EditorOptions
    extend T::Sig

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def self.call
      {
        genres: tally("genres", Movie, Show), networks: tally("networks", Show), studios: tally("studios", Movie),
        keywords: tally("keywords", Movie, Show).first(300),
        shows: Show.order(:sort_title).pluck(:id, :title, :year).map { |id, title, year| { id: id, title: title, year: year } },
        collections: Collection.order(:sort_title).pluck(:id, :title).map { |id, title| { id: id, title: title } },
        youtube_channels: Channel.order(:title).pluck(:id, :title).map { |id, title| { id: id, title: title } },
        profiles: Profile.order(:name).pluck(:id, :name).map { |id, name| { id: id, name: name } },
        live_streams: LiveStream.order(:sort_title).pluck(:id, :name, :mlb_team_id).map { |id, name, team| { id: id, name: name, mlb_team: !team.nil? } },
        mlb_teams: mlb_teams,
        decades: decades,
        time_zone: AppSetting.cached.zone.tzinfo.name
      }
    end

    # The clubs whose games a channel can carry, once the household has
    # an MLB.tv account; none when MLB's list can't be read.
    sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.mlb_teams
      return [] unless MlbSetting.exists?

      Mlb::Schedule.new.teams.map { |team| { id: team.fetch("id"), name: team.fetch("name") } }
    rescue Mlb::Schedule::Error
      []
    end
    private_class_method :mlb_teams

    # The decades the library's shows and films come from, most first.
    sig { returns(T::Array[T::Hash[Symbol, Integer]]) }
    def self.decades
      counts = Hash.new(0)
      [ Show, Movie ].each do |model|
        model.where.not(year: nil).group(Arel.sql("(year / 10) * 10")).count.each { |decade, count| counts[decade.to_i] += count }
      end
      counts.sort_by { |decade, _| -decade }.map { |decade, count| { value: decade, count: count } }
    end
    private_class_method :decades

    # A string-array column's values across titles, most common first.
    sig { params(column: String, models: T.class_of(ApplicationRecord)).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def self.tally(column, *models)
      counts = Hash.new(0)
      models.each do |model|
        model.where.not(column => []).group(Arel.sql("unnest(#{column})")).count.each { |value, count| counts[value] += count }
      end
      counts.sort_by { |value, count| [ -count, value.to_s ] }.map { |value, count| { value: value, count: count } }
    end
    private_class_method :tally
  end
end

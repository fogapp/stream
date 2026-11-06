# typed: strict
# frozen_string_literal: true

module Recommendations
  # A title as a vector of what it's made of (PROPOSAL §7.1): genres, the
  # people who made it and are in it, the series it's part of, its decade,
  # and the words of its overview, each hashed into one of 512 dimensions
  # and weighted by how much it says about a title. Cosine distance between
  # two such vectors is "how alike": no model, no cloud. A video (PROPOSAL
  # §5.4) is its tags, the words of its title and description, and its
  # channel.
  module Embedder
    extend T::Sig

    DIMENSIONS = 512

    WEIGHTS = T.let({
      genre: 3.0, director: 2.5, creator: 2.5, cast: 1.5, collection: 3.0, decade: 1.0, word: 0.4,
      tag: 2.0, title_word: 1.2, channel: 1.0
    }.freeze, T::Hash[Symbol, Float])
    # A video's tags past these are the channel's boilerplate, not this video.
    TAGS = 20
    URL = %r{https?://\S+}
    CAST = 8
    WORDS = 40

    STOPWORDS = T.let(%w[
      about after again against also among another around because been before being between both came come could does
      down each even every find from have here into just know like made make many more most much must never only other
      over said same should since some still such take than that their them then there these they thing this those
      through time under until very want were what when where which while will with within without would year years
      your life lives world story when while young finds must becomes begins after their
    ].to_set.freeze, T::Set[String])

    sig { params(title: T.any(Movie, Show, Video)).returns(T.nilable(T::Array[Float])) }
    def self.vector(title)
      features = title.is_a?(Video) ? video_features(title) : features(title)
      return nil if features.empty?

      vector = T.let(Array.new(DIMENSIONS, 0.0), T::Array[Float])
      features.each do |token, weight|
        hash = Zlib.crc32(token)
        sign = Zlib.crc32("#{token}#").odd? ? 1.0 : -1.0
        vector[hash % DIMENSIONS] = vector.fetch(hash % DIMENSIONS) + (sign * weight)
      end
      norm = Math.sqrt(vector.sum { |value| value * value })
      norm.zero? ? nil : vector.map { |value| (value / norm).round(6).to_f }
    end

    sig { params(title: T.any(Movie, Show)).returns(T::Hash[String, Float]) }
    def self.features(title)
      features = T.let({}, T::Hash[String, Float])
      add = ->(token, weight) { features[token] = features.fetch(token, 0.0) + weight }
      Array(title.genres).each { |genre| add.call("g:#{genre.downcase}", WEIGHTS.fetch(:genre)) }
      credits = title.credits.to_a
      credits.select { |credit| credit.role_enum == Credit::Role::Cast }.first(CAST)
        .each { |credit| add.call("p:#{credit.person_id}", WEIGHTS.fetch(:cast)) }
      credits.each do |credit|
        case credit.role_enum
        when Credit::Role::Director then add.call("p:#{credit.person_id}", WEIGHTS.fetch(:director))
        when Credit::Role::Creator then add.call("p:#{credit.person_id}", WEIGHTS.fetch(:creator))
        end
      end
      add.call("c:#{title.tmdb_collection_id}", WEIGHTS.fetch(:collection)) if title.is_a?(Movie) && title.tmdb_collection_id
      add.call("d:#{title.year.to_i / 10}", WEIGHTS.fetch(:decade)) if title.year
      words(title.overview).each { |word, count| add.call("w:#{word}", WEIGHTS.fetch(:word) * Math.log(1 + count)) }
      features
    end

    sig { params(video: Video).returns(T::Hash[String, Float]) }
    def self.video_features(video)
      features = T.let({}, T::Hash[String, Float])
      add = ->(token, weight) { features[token] = features.fetch(token, 0.0) + weight }
      video.tags.map { |tag| tag.to_s.downcase.strip }.reject(&:empty?).uniq.first(TAGS)
        .each { |tag| add.call("t:#{tag}", WEIGHTS.fetch(:tag)) }
      words(video.title).each_key { |word| add.call("w:#{word}", WEIGHTS.fetch(:title_word)) }
      # Links are sponsors and socials, not what it's about.
      words(video.description.to_s.gsub(URL, " ")).each { |word, count| add.call("w:#{word}", WEIGHTS.fetch(:word) * Math.log(1 + count)) }
      add.call("ch:#{video.channel_id}", WEIGHTS.fetch(:channel))
      features
    end

    sig { params(text: T.nilable(String)).returns(T::Hash[String, Integer]) }
    def self.words(text)
      T.cast(text.to_s.downcase.scan(/[a-z]{4,}/), T::Array[String]).reject { |word| STOPWORDS.include?(word) }.tally
        .sort_by { |word, count| [ -count, word ] }.first(WORDS).to_h
    end
    private_class_method :features, :video_features, :words
  end
end

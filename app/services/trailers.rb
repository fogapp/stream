# typed: strict
# frozen_string_literal: true

# Which trailer a title has (PROPOSAL §7.1–7.2), from TMDB's list of its
# videos: an official YouTube trailer, in the metadata language if there is
# one, the most recent first; a teaser when there's no trailer.
module Trailers
  extend T::Sig

  sig { params(videos: T::Array[T::Hash[String, T.untyped]], language: String).returns(T.nilable(T::Hash[String, T.untyped])) }
  def self.best(videos, language: "en")
    youtube = videos.select { |video| video["site"] == "YouTube" && video["key"].to_s.match?(Youtube::Urls::VIDEO_ID) }
    candidates = youtube.select { |video| video["type"] == "Trailer" }.presence || youtube.select { |video| video["type"] == "Teaser" }
    candidates.max_by do |video|
      [ video["official"] ? 1 : 0, video["iso_639_1"] == language.split("-").first ? 1 : 0, video["published_at"].to_s ]
    end
  end

  # Remembers a title's trailer, and fetches it when it's new (or changed)
  # and Settings allow. Nothing to remember clears nothing: a title that
  # loses its trailer on TMDB keeps the one it has.
  sig { params(owner: T.any(Movie, Show), videos: T::Array[T::Hash[String, T.untyped]], language: String).void }
  def self.remember(owner, videos, language: "en")
    # A title with none leaves no Trailer row: FetchTrailersJob goes by this.
    owner.update_columns(trailer_checked_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    video = best(videos, language: language)
    return if video.nil?

    trailer = Trailer.unscoped.find_or_initialize_by(owner: owner)
    return if trailer.persisted? && trailer.youtube_id == video["key"]

    FileUtils.rm_f(trailer.path) if trailer.persisted?
    trailer.assign_attributes(household_id: owner.household_id, youtube_id: video["key"], name: video["name"].to_s.first(200),
      state: Trailer::State::Queued.serialize, error: nil, attempts: 0, size: nil)
    trailer.save!
    FetchTrailerJob.perform_later(trailer.id) if AppSetting.cached.fetch_trailers
  end

  # After a restore (FogBackup::Restorer): backups leave trailer videos out,
  # since they can be fetched again, so a ready trailer whose file didn't
  # come back goes back in the queue rather than quietly never showing.
  sig { void }
  def self.requeue_missing!
    fetch = AppSetting.current.fetch_trailers
    Trailer.unscoped.where(state: Trailer::State::Ready.serialize).find_each do |trailer|
      next if trailer.path.file?

      trailer.update!(state: Trailer::State::Queued.serialize, error: nil, attempts: 0, size: nil)
      FetchTrailerJob.perform_later(trailer.id) if fetch
    end
  end

  # A signed URL for a ready trailer, like artwork's: good for exactly that
  # file, so the browser can cache it.
  sig { params(trailer: T.nilable(Trailer)).returns(T.nilable(String)) }
  def self.url(trailer)
    return nil if trailer.nil? || !trailer.ready?

    "/trailers/#{trailer.id}/#{signature(trailer.id)}.mp4"
  end

  sig { params(id: String, signature: String).returns(T::Boolean) }
  def self.valid?(id, signature) = ActiveSupport::SecurityUtils.secure_compare(signature(id), signature.to_s)

  sig { params(id: String).returns(String) }
  def self.signature(id)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.key_generator.generate_key("stream/trailer-urls", 32), id).first(24)
  end
  private_class_method :signature

  # For a title's page and Home's hero: the playable trailer, if any.
  sig { params(owner: T.any(Movie, Show)).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
  def self.json(owner)
    trailer = Trailer.find_by(owner: owner)
    link = url(trailer)
    link && { url: link, name: trailer&.name }
  end
end

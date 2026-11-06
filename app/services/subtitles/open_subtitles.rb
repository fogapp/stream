# typed: strict
# frozen_string_literal: true

module Subtitles
  # OpenSubtitles' REST API (PROPOSAL §5.5): search by the file's own hash
  # (a MediaFile fingerprint is the OpenSubtitles hash) and the title's ids,
  # then download one — which, with an account, needs a login token.
  class OpenSubtitles
    extend T::Sig
    include UpstreamHttpClient

    BASE = "https://api.opensubtitles.com/api/v1"
    DOWNLOAD_HOSTS = T.let(/\A([\w-]+\.)*opensubtitles\.(com|org)\z/, Regexp)

    class Error < UpstreamHttpClient::Error; end

    class Candidate < T::Struct
      const :file_id, Integer
      const :language, String
      const :hash_match, T::Boolean
      const :downloads, Integer
      const :hearing_impaired, T::Boolean
      const :release, T.nilable(String)
    end

    sig { params(setting: OpenSubtitlesSetting).void }
    def initialize(setting)
      @setting = setting
    end

    sig { override.returns(String) }
    def service_name = "OpenSubtitles"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = Error

    sig { returns([ T::Boolean, String ]) }
    def test_connection
      answer_test do
        if @setting.username.present?
          token
          "Signed in to OpenSubtitles as #{@setting.username}"
        else
          get("/infos/formats")
          "OpenSubtitles accepted the API key"
        end
      end
    end

    # Human subtitles in a language for a file, best first: the exact file
    # (hash) before the same title, then the most downloaded.
    sig { params(file: MediaFile, language: String).returns(T::Array[Candidate]) }
    def search(file, language)
      params = { languages: language, ai_translated: "exclude", machine_translated: "exclude" }
      params[:moviehash] = file.fingerprint if file.fingerprint.to_s.match?(/\A\h{16}\z/)
      playable = file.editions.first&.playable
      case playable
      when Movie
        params[:tmdb_id] = playable.tmdb_id if playable.tmdb_id
        params[:imdb_id] = playable.imdb_id.to_s.delete_prefix("tt").to_i if playable.imdb_id
      when Episode
        show = playable.show
        params[:parent_tmdb_id] = show.tmdb_id if show&.tmdb_id
        params[:season_number] = playable.season_number
        params[:episode_number] = playable.episode_number if playable.episode_number
      end
      data = get("/subtitles", params)
      Array(data["data"]).filter_map { |entry| candidate(entry) }
        .select { |found| found.language.casecmp?(language) }
        .sort_by { |found| [ found.hash_match ? 0 : 1, found.hearing_impaired ? 1 : 0, -found.downloads ] }
    end

    # The subtitle's text (SRT), and how many downloads are left today.
    sig { params(candidate: Candidate).returns([ String, T.nilable(Integer), T.nilable(Time) ]) }
    def download(candidate)
      headers = { "Api-Key" => @setting.api_key.to_s }
      headers["Authorization"] = "Bearer #{token}" if @setting.username.present?
      response = http_post_json("#{BASE}/download", body: { file_id: candidate.file_id, sub_format: "srt" }, headers: headers)
      data = parse_object(response)
      link = data["link"].to_s
      host = URI.parse(link).host.to_s
      raise Error, "OpenSubtitles pointed the download somewhere else" unless link.start_with?("https://") && host.match?(DOWNLOAD_HOSTS)

      text = http_get(link, max_bytes: 5 * 1024 * 1024).body.to_s
      reset = data["reset_time_utc"].presence && Time.zone.parse(data["reset_time_utc"].to_s)
      [ text, data["remaining"]&.to_i, reset ]
    rescue URI::InvalidURIError
      raise Error, "OpenSubtitles answered with something unexpected"
    end

    private

    sig { params(entry: T.untyped).returns(T.nilable(Candidate)) }
    def candidate(entry)
      attributes = entry.is_a?(Hash) ? entry["attributes"] : nil
      file_id = attributes.is_a?(Hash) ? Array(attributes["files"]).first&.dig("file_id") : nil
      return nil if attributes.nil? || file_id.nil?

      Candidate.new(file_id: file_id.to_i, language: attributes["language"].to_s, hash_match: attributes["moviehash_match"] == true,
        downloads: attributes["download_count"].to_i, hearing_impaired: attributes["hearing_impaired"] == true,
        release: attributes["release"].presence)
    end

    sig { params(path: String, params: T::Hash[Symbol, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def get(path, params = {})
      query = params.sort.to_h.map { |key, value| "#{key}=#{CGI.escape(value.to_s)}" }.join("&")
      response = http_get("#{BASE}#{path}#{query.empty? ? '' : "?#{query}"}", headers: { "Api-Key" => @setting.api_key.to_s })
      parse_object(response)
    end

    # A login token, kept for a day.
    sig { returns(String) }
    def token
      Rails.cache.fetch("opensubtitles:token:#{@setting.id}:#{@setting.updated_at.to_i}", expires_in: 23.hours) do
        response = http_post_json("#{BASE}/login", body: { username: @setting.username, password: @setting.password },
          headers: { "Api-Key" => @setting.api_key.to_s })
        parse_object(response)["token"].presence || raise(Error, "OpenSubtitles gave no token")
      end
    end
  end
end

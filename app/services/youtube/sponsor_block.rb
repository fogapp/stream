# typed: strict
# frozen_string_literal: true

module Youtube
  # SponsorBlock's segments for a video (PROPOSAL §5.4). Asked by the first
  # four characters of the id's SHA-256, as SponsorBlock recommends, so the
  # server can't tell which video we're watching.
  class SponsorBlock
    extend T::Sig
    include UpstreamHttpClient

    BASE = "https://sponsor.ajay.app/api/skipSegments"

    class Error < UpstreamHttpClient::Error; end

    sig { override.returns(String) }
    def service_name = "SponsorBlock"

    sig { override.returns(T.class_of(UpstreamHttpClient::Error)) }
    def error_class = Error

    # [{ category, start, end, uuid }] for the video; empty when nobody has
    # submitted any.
    sig { params(youtube_id: String).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
    def segments(youtube_id)
      raise Error, "not a video id" unless youtube_id.match?(Urls::VIDEO_ID)

      prefix = Digest::SHA256.hexdigest(youtube_id)[0, 4]
      query = URI.encode_www_form(categories: SponsorSegment::Category.values.map(&:serialize).to_json, actionTypes: '["skip"]')
      response = http_get("#{BASE}/#{prefix}?#{query}")
      entries = parse_json(response)
      match = Array(entries).find { |entry| entry.is_a?(Hash) && entry["videoID"] == youtube_id }
      Array(match&.dig("segments")).filter_map do |segment|
        start, finish = Array(segment["segment"]).map(&:to_f)
        category = SponsorSegment::Category.try_deserialize(segment["category"].to_s)
        next if category.nil? || start.nil? || finish.nil? || finish <= start

        { category: category, start: start, end: finish, uuid: segment["UUID"].to_s }
      end
    rescue Error => e
      # 404 is SponsorBlock's "nothing for that prefix".
      raise unless e.status == 404

      []
    end
  end
end

# typed: false
# frozen_string_literal: true

require "rails_helper"

# Every service Stream calls, answering badly the two ways services do: a
# page that isn't JSON (a login portal, a proxy's error page, a half-started
# container), and a rate limit. Each must come back as that service's own
# error, saying what went wrong — never a JSON::ParserError from deep inside
# a sync, and never a rate limit mistaken for a broken service.
RSpec.describe "Upstream clients answering badly" do
  let(:audio) { Tempfile.create([ "audio", ".ogg" ]).tap { |file| file.write("ogg") && file.flush } }

  # Hook's address and token are what fog injects (Hook::Client).
  before { stub_const("ENV", ENV.to_h.merge("HOOK_URL" => "http://hook.lan", "HOOK_API_TOKEN" => "t")) }
  after { File.delete(audio.path) if File.exist?(audio.path) }

  CLIENTS = {
    "TMDB" => [ %r{api\.themoviedb\.org}, ->(_) { Tmdb::Client.new(api_key: "k").movie(949) }, Tmdb::Client::Error ],
    "Trakt" => [ %r{api\.trakt\.tv}, ->(_) { Trakt::Client.new(TraktSetting.new(client_id: "c", client_secret: "s")).get("/users/settings", token: "t") },
                 Trakt::Client::Error ],
    "Immich" => [ %r{immich\.lan}, ->(_) { Immich::Client.new(ImmichSetting.new(url: "http://immich.lan:2283", api_key: "k")).people },
                  Immich::Client::Error ],
    "Hook" => [ %r{hook\.lan}, ->(_) { Hook::Client.new(on_behalf_of: "sam@example.com").search(media_kind: "movie", query: "heat") },
                Hook::Client::Error ],
    "plex.tv" => [ %r{plex\.tv}, ->(_) { Plex::Account.new(token: "t", client_id: "c").owner }, Plex::Account::Error ],
    "a Plex server" => [ %r{plex\.lan}, ->(_) { Plex::Server.new(url: "http://plex.lan:32400", token: "t", client_id: "c").identity },
                         Plex::Server::Error ],
    "SponsorBlock" => [ %r{sponsor\.ajay\.app}, ->(_) { Youtube::SponsorBlock.new.segments("Ql7w1yX7hbI") }, Youtube::SponsorBlock::Error ],
    "OpenSubtitles" => [ %r{api\.opensubtitles\.com},
                         ->(_) { Subtitles::OpenSubtitles.new(OpenSubtitlesSetting.new(api_key: "k", languages: %w[en])).send(:get, "/infos/formats") },
                         Subtitles::OpenSubtitles::Error ],
    "Whisper" => [ %r{whisper\.lan}, ->(path) { Transcripts::WhisperClient.new(WhisperSetting.new(url: "http://whisper.lan:9000")).transcribe(path) },
                   Transcripts::WhisperClient::Error ]
  }.freeze

  CLIENTS.each do |name, (host, call, error)|
    describe name do
      it "names a page that isn't JSON as its own error" do
        stub_request(:any, host).to_return(status: 200, body: "<html><body>Please sign in</body></html>",
          headers: { "Content-Type" => "text/html" })

        expect { call.call(Pathname(audio.path)) }.to raise_error(error, /isn't JSON|something unexpected|without a MediaContainer/)
      end

      it "names a rate limit as a rate limit, with what the service said" do
        stub_request(:any, host).to_return(status: 429, body: { message: "Slow down" }.to_json,
          headers: { "Content-Type" => "application/json", "Retry-After" => "30" })

        expect { call.call(Pathname(audio.path)) }.to raise_error(UpstreamHttpClient::RateLimitError) do |raised|
          # Its own error too, so a `rescue #{error}` around the call catches it.
          expect(raised).to be_a(error)
          expect(raised.status).to eq(429)
          expect(raised.message).to include("rate limited")
        end
      end
    end
  end
end

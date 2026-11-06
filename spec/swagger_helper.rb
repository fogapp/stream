# typed: false
# frozen_string_literal: true

require "rails_helper"

# The OpenAPI document (PROPOSAL §7.6), for a native client to be generated
# from: the specs in spec/requests/openapi describe the endpoints a player
# app needs and run against the real API, so the document can't drift from
# it. `bin/rails rswag:specs:swaggerize` writes swagger/v1/openapi.yaml.
RSpec.configure do |config|
  config.openapi_root = Rails.root.join("swagger").to_s

  nullable = ->(type, **rest) { { type: type, nullable: true, **rest } }
  images = { type: :object, description: "Rendered artwork by kind (poster, backdrop, logo, still, thumb): src, srcset, placeholder, colour",
             additionalProperties: { type: :object } }

  config.openapi_specs = {
    "v1/openapi.yaml" => {
      openapi: "3.0.1",
      info: {
        title: "Stream API",
        version: "v1",
        description: "The household's video player. Sign in for a bearer token, choose a profile (X-Stream-Profile), " \
                     "then browse and start playback sessions; media bytes come from the stream URLs a session returns."
      },
      servers: [ { url: "/", description: "This server" } ],
      components: {
        securitySchemes: {
          bearerAuth: { type: :http, scheme: :bearer, description: "A session token (POST /api/v1/session, or TV pairing) or an API token" },
          profileToken: { type: :apiKey, in: :header, name: "X-Stream-Profile",
                           description: "The token from POST /api/v1/profiles/{id}/select; without one, the device's default or the first profile without a PIN" }
        },
        schemas: {
          Errors: { type: :object, properties: { errors: { type: :array, items: { type: :string } } }, required: %w[errors] },
          User: {
            type: :object, required: %w[id email name role household_id visitor],
            properties: { id: { type: :string, format: :uuid }, email: { type: :string }, name: { type: :string }, role: { type: :string },
                          household_id: { type: :string, format: :uuid }, visitor: { type: :boolean } }
          },
          Session: { type: :object, required: %w[token user], properties: { token: { type: :string }, user: { "$ref" => "#/components/schemas/User" } } },
          Pairing: {
            type: :object, required: %w[code poll_token expires_at],
            properties: { code: { type: :string, example: "ABCD-EFGH" }, poll_token: { type: :string }, expires_at: { type: :string, format: "date-time" } }
          },
          Profile: {
            type: :object, required: %w[id name color has_pin kind],
            properties: { id: { type: :string, format: :uuid }, name: { type: :string }, color: { type: :string }, avatar: nullable.call(:string),
                          has_pin: { type: :boolean }, kind: { type: :string, enum: %w[standard kid] } }
          },
          CurrentProfile: {
            type: :object, required: %w[profile chosen needs_picker],
            properties: { profile: { "$ref" => "#/components/schemas/Profile" }, chosen: { type: :boolean },
                          device_default_id: nullable.call(:string, format: :uuid), needs_picker: { type: :boolean } }
          },
          MovieCard: {
            type: :object, required: %w[kind id title images watched],
            properties: { kind: { type: :string, enum: %w[movie] }, id: { type: :string, format: :uuid }, title: { type: :string },
                          year: nullable.call(:integer), images: images, progress: nullable.call(:number), watched: { type: :boolean },
                          tmdb_id: nullable.call(:integer), imdb_id: nullable.call(:string) }
          },
          LetterStart: {
            type: :object, required: %w[letter index],
            properties: { letter: { type: :string, description: "A–Z, or # for anything else" },
                          index: { type: :integer, description: "Position of the letter's first title in the A–Z grid" } }
          },
          ShowCard: {
            type: :object, required: %w[kind id title images unwatched_count],
            properties: { kind: { type: :string, enum: %w[show] }, id: { type: :string, format: :uuid }, title: { type: :string },
                          year: nullable.call(:integer), images: images, unwatched_count: { type: :integer },
                          tmdb_id: nullable.call(:integer), tvdb_id: nullable.call(:integer), imdb_id: nullable.call(:string),
                          arrival: { type: :string, description: "In Home's Recently added, standing for a batch of its episodes: " \
                                                                 "what arrived (\"New show\", \"Season 2 added\", \"12 new episodes\")" },
                          season_number: nullable.call(:integer, description: "With arrival: the one season the batch came in, " \
                                                                              "to open on; absent or null opens the show") }
          },
          EpisodeCard: {
            type: :object, required: %w[kind id code season_number],
            properties: { kind: { type: :string, enum: %w[episode] }, id: { type: :string, format: :uuid }, code: { type: :string },
                          title: nullable.call(:string), season_number: { type: :integer }, episode_number: nullable.call(:integer),
                          images: images, progress: nullable.call(:number), watched: { type: :boolean } }
          },
          Home: {
            type: :object, required: %w[profile heroes hubs layout],
            properties: {
              hero: { type: :object, nullable: true, description: "One of heroes, chosen at random" },
              heroes: { type: :array, items: { type: :object }, description: "What may take the top of the page" },
              hubs: { type: :array, items: { type: :object, required: %w[key title kind items],
                                             properties: { key: { type: :string }, title: { type: :string },
                                                           kind: { type: :string, enum: %w[continue wide poster videos clips] },
                                                           items: { type: :array, items: { type: :object } } } } },
              layout: { type: :array, items: { type: :object } }
            }
          },
          PlaybackSession: {
            type: :object, required: %w[id method source progress_url subtitles resume_at],
            properties: {
              id: { type: :string, format: :uuid },
              method: { type: :string, enum: PlaybackSession::Method.values.map(&:serialize) },
              title: { type: :string }, subtitle: nullable.call(:string),
              source: { type: :object, required: %w[kind url], properties: { kind: { type: :string, enum: %w[file hls] }, url: { type: :string },
                                                                            mime_type: nullable.call(:string) } },
              progress_url: { type: :string, description: "POST { position, ended } here as it plays" },
              subtitles: { type: :array, items: { type: :object } },
              chapters: { type: :array, items: { type: :object } },
              markers: { type: :array, items: { type: :object } },
              next_up: { type: :object, nullable: true },
              resume_at: { type: :number },
              decision: { type: :object, properties: { summary: { type: :string } } },
              fallback: {
                type: :object, nullable: true,
                description: "Carried on a rung down from a session that failed (POST …/fallback): what it fell from, and whether " \
                             "to try climbing back (POST …/upgrade) at the next seek",
                properties: {
                  from_method: { type: :string, enum: PlaybackSession::Method.values.map(&:serialize) },
                  failure_class: { type: :string, enum: PlaybackSession::FailureClass.values.map(&:serialize) },
                  upgradable: { type: :boolean }
                }
              },
              live_stream: {
                type: :object, nullable: true,
                description: "A camera or web stream (PROPOSAL §7.8): source is a live HLS playlist that opens at its newest; " \
                             "POST progress to keep the session open — its answer's relay says how the stream is going",
                properties: { id: { type: :string, format: :uuid }, name: { type: :string }, kind: { type: :string, enum: %w[camera web youtube mlb] },
                              library_id: { type: :string, format: :uuid } }
              },
              live: {
                type: :object, nullable: true, description: "Tuned in on a Grid channel (PROPOSAL §7.7): where live is",
                properties: {
                  station_id: { type: :string, format: :uuid }, number: { type: :string }, name: { type: :string },
                  airing_id: { type: :string, format: :uuid }, starts_at: { type: :string, format: "date-time" },
                  ends_at: { type: :string, format: "date-time" }, server_now: { type: :string, format: "date-time" }
                }
              }
            }
          },
          Station: {
            type: :object, required: %w[id number name hidden favorite],
            properties: {
              id: { type: :string, format: :uuid }, number: { type: :string, example: "4.1" }, name: { type: :string },
              call_sign: nullable.call(:string), hidden: { type: :boolean }, favorite: { type: :boolean },
              live_stream_id: { type: :string, format: :uuid, nullable: true,
                                description: "Shows this camera or web stream instead of programming: one program in the guide, all day" }
            }
          },
          LiveStream: {
            type: :object, required: %w[id name kind library_id source status tracks],
            description: "A camera, web, YouTube or MLB.tv stream (PROPOSAL §7.8). Never its address: source is scheme://host:port, " \
                         "or a YouTube stream's or MLB.tv game's own link",
            properties: {
              id: { type: :string, format: :uuid }, name: { type: :string }, kind: { type: :string, enum: %w[camera web youtube mlb] },
              feed: { type: :string, enum: %w[home away], nullable: true, description: "An MLB.tv game's: which team's TV broadcast it plays" },
              library_id: { type: :string, format: :uuid }, description: nullable.call(:string), content_rating: nullable.call(:string),
              source: { type: :string, example: "rtsps://192.168.1.1:7441" }, status: { type: :string, enum: %w[online offline] },
              last_seen_at: { type: :string, format: "date-time", nullable: true },
              still_url: { type: :string, nullable: true, description: "Its picture a few minutes ago, signed for an image request" },
              tracks: { type: :array, items: { type: :object } }
            }
          },
          Airing: {
            type: :object, required: %w[id station_id starts_at ends_at kind playable_id title filler reminded],
            properties: {
              id: { type: :string, format: :uuid }, station_id: { type: :string, format: :uuid },
              starts_at: { type: :string, format: "date-time" }, ends_at: { type: :string, format: "date-time" },
              kind: { type: :string, enum: %w[movie episode extra video live_stream],
                      description: "live_stream: a channel showing a camera or web stream — playable_id is the stream" },
              playable_id: { type: :string, format: :uuid },
              title: { type: :string, description: "The show's title for an episode" }, subtitle: nullable.call(:string),
              episode_title: nullable.call(:string), code: nullable.call(:string), show_id: nullable.call(:string),
              channel_id: nullable.call(:string), year: nullable.call(:integer), content_rating: nullable.call(:string),
              overview: nullable.call(:string),
              images: { type: :object }, reason: { type: :string }, filler: { type: :boolean, description: "Between programs" },
              reminded: { type: :boolean }
            }
          },
          Guide: {
            type: :object, required: %w[now from to time_zone stations],
            properties: {
              now: { type: :string, format: "date-time" }, from: { type: :string, format: "date-time" }, to: { type: :string, format: "date-time" },
              time_zone: { type: :string, example: "America/New_York" },
              stations: { type: :array, items: { allOf: [ { "$ref" => "#/components/schemas/Station" },
                                                          { type: :object, properties: { airings: { type: :array, items: { "$ref" => "#/components/schemas/Airing" } } } } ] } }
            }
          }
        }
      }
    }
  }
  config.openapi_format = :yaml
end

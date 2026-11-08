# typed: strict
# frozen_string_literal: true

# Where Stream keeps what it makes (CLAUDE.md, media invariant 1): `storage`
# for what's worth keeping and backing up (artwork, trickplay, extracted
# subtitles, trailers, tools), `cache` for what can always be made again
# (transcode segments, optimized versions, downloads in progress). fog
# mounts both; STREAM_STORAGE_DIR and STREAM_CACHE_DIR move them (a spec's
# temporary directory), read on every call so a stubbed ENV is seen.
module StreamPaths
  extend T::Sig

  sig { returns(Pathname) }
  def self.storage = Pathname.new(ENV.fetch("STREAM_STORAGE_DIR") { Rails.root.join("storage").to_s })

  sig { returns(Pathname) }
  def self.cache = Pathname.new(ENV.fetch("STREAM_CACHE_DIR") { Rails.root.join("tmp", "cache", "stream").to_s })
end

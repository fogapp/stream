# typed: strict
# frozen_string_literal: true

module LiveStreams
  # The HLS playlists a link resolves to (LiveStreams::Resolver): the
  # picture's, and the sound's when it's sent apart.
  class Resolved < T::Struct
    const :video, String
    # Nil when one playlist carries both.
    const :audio, T.nilable(String), default: nil
    # The User-Agent yt-dlp fetched the playlists with, for ffmpeg to send
    # too: MLB.tv's Fastly edge answers ffmpeg's own (Lavf/…) with 403
    # (2026-10-15). Nil when yt-dlp didn't say.
    const :user_agent, T.nilable(String), default: nil
  end
end

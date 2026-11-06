# typed: strict
# frozen_string_literal: true

module Playback
  # The source URL a remote transcoder's ffmpeg reads the original from
  # (/media/n/<token>/source): signs one TranscodeRun, like a stream token
  # signs a session, because ffmpeg sends no Authorization header. Good
  # while the run is live.
  module RunToken
    extend T::Sig

    sig { params(run: TranscodeRun).returns(String) }
    def self.issue(run) = SignedToken.issue("run:", run.id.to_s)

    sig { params(token: String).returns(T.nilable(TranscodeRun)) }
    def self.verify(token)
      id, = SignedToken.fields("run:", token)
      id && TranscodeRun.remote.live.find_by(id: id)
    end
  end
end

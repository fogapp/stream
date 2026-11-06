# typed: strict
# frozen_string_literal: true

module Playback
  # Signs an offline download's URL (/media/d/<token>/…), because the
  # service worker fetching it in the background sends no Authorization
  # header. Good while the download row lives.
  module DownloadToken
    extend T::Sig

    sig { params(download: OfflineDownload).returns(String) }
    def self.issue(download) = SignedToken.issue("download:", download.id.to_s)

    sig { params(token: String).returns(T.nilable(OfflineDownload)) }
    def self.verify(token)
      id, = SignedToken.fields("download:", token)
      id && OfflineDownload.unscoped.live.find_by(id: id)
    end
  end
end

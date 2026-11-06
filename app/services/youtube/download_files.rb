# typed: strict
# frozen_string_literal: true

module Youtube
  # A video Stream fetched and the sidecars yt-dlp wrote beside it: exactly
  # its name plus one of theirs, never another file that merely starts the
  # same way. Callers check the path is inside the download folder first.
  module DownloadFiles
    extend T::Sig

    SIDECARS = T.let(%w[.info.json .jpg .jpeg .png .webp .nfo].freeze, T::Array[String])

    sig { params(path: String).void }
    def self.delete(path)
      folder = File.dirname(path)
      base = File.basename(path.delete_suffix(File.extname(path)))
      extras = Dir.glob("*", base: folder).select { |name| name.start_with?(base) && sidecar?(name.delete_prefix(base)) }
      [ path, *extras.map { |name| File.join(folder, name) } ].each { |file| FileUtils.rm_f(file) }
    end

    sig { params(suffix: String).returns(T::Boolean) }
    def self.sidecar?(suffix) = SIDECARS.include?(suffix) || suffix.match?(/\A\.[a-z-]+\.(vtt|srt)\z/i)
  end
end

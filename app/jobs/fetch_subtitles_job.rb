# typed: strict
# frozen_string_literal: true

# Missing subtitle languages for a movie or episode, from OpenSubtitles
# (PROPOSAL §5.5). Each wanted language that no track already covers gets
# the best human subtitle — the same file first — once.
class FetchSubtitlesJob < ApplicationJob
  extend T::Sig

  queue_as :default
  limits_concurrency to: 1, key: ->(_media_file_id) { "opensubtitles" }
  retry_on UpstreamHttpClient::RateLimitError, wait: 10.minutes, attempts: 5

  sig { params(media_file_id: String).void }
  def perform(media_file_id)
    file = MediaFile.unscoped.includes(:media_streams).find_by(id: media_file_id)
    setting = file && OpenSubtitlesSetting.unscoped.find_by(household_id: file.household_id)
    return if file.nil? || setting.nil? || !setting.enabled || setting.exhausted?
    return unless Edition.where(media_file_id: file.id, playable_type: %w[Movie Episode]).exists?

    missing = setting.languages.reject { |language| covered?(file, language) }
    return if missing.empty?

    client = Subtitles::OpenSubtitles.new(setting)
    AnalysisRun.track(file, AnalysisRun::Step::SubtitleFetch, tool_version: "opensubtitles") do
      missing.each do |language|
        best = client.search(file, language).first
        next if best.nil?

        text, remaining, resets = client.download(best)
        setting.update!(remaining_downloads: remaining, resets_at: resets)
        directory = Subtitles::Extractor.downloads_dir(file)
        FileUtils.mkdir_p(directory)
        directory.join("#{language}.#{best.file_id}.srt").write(text)
        break if setting.exhausted?
      end
    end
  end

  private

  sig { params(file: MediaFile, language: String).returns(T::Boolean) }
  def covered?(file, language)
    Subtitles::Tracks.for(file).any? do |track|
      !track.forced && track.format != Subtitles::Tracks::Format::Pgs && Subtitles::Languages.same?(language, track.language)
    end
  end
end

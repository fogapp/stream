# typed: strict
# frozen_string_literal: true

module Analysis
  # Runs one analysis step on a file again (the file page's checklist):
  # what the step made before is forgotten, so it's made again rather than
  # skipped as done, and its job is queued.
  module Rerun
    extend T::Sig

    sig { params(media_file: MediaFile, step: AnalysisRun::Step).void }
    def self.call(media_file, step)
      case step
      when AnalysisRun::Step::Probe
        media_file.update!(state: MediaFile::State::Discovered.serialize) unless media_file.state_enum == MediaFile::State::Missing
        ProbeMediaFileJob.perform_later(media_file.id)
      when AnalysisRun::Step::Keyframes
        media_file.update!(keyframes: nil, keyframes_source: nil)
        IndexKeyframesJob.perform_later(media_file.id)
      when AnalysisRun::Step::Match then MatchMediaFileJob.perform_later(media_file.id, media_file.library_id)
      when AnalysisRun::Step::Artwork
        # A frame that gave up waits for its file to change; asking again is that change.
        Artwork.where(source: Artwork::Source::Frame.serialize, source_ref: media_file.id).update_all(consecutive_failures: 0) # rubocop:disable Rails/SkipsModelValidations
        media_file.editions.each { |edition| SyncArtworkJob.perform_later(edition.playable_type, edition.playable_id) }
      when AnalysisRun::Step::Trickplay, AnalysisRun::Step::Loudness
        AnalysisRun.forget!(media_file, step)
        AnalyzeMediaFileJob.perform_later(media_file.id)
      when AnalysisRun::Step::SubtitleFetch then FetchSubtitlesJob.perform_later(media_file.id)
      when AnalysisRun::Step::Transcript
        media_file.transcript&.destroy
        BuildTranscriptJob.perform_later(media_file.id)
      when AnalysisRun::Step::Markers
        episode = media_file.editions.map(&:playable).grep(Episode).first
        media_file.audio_fingerprints.delete_all
        if episode
          Markers::Detector.forget_season(episode.show_id, episode.season_number)
          DetectMarkersJob.perform_later(episode.show_id, episode.season_number)
        end
      when AnalysisRun::Step::Subtitles
        FileUtils.rm_rf(Subtitles::Extractor.root.join(media_file.id))
        AnalysisRun.forget!(media_file, step)
        AnalyzeMediaFileJob.perform_later(media_file.id)
      when AnalysisRun::Step::YoutubeDetails
        media_file.editions.map(&:playable).grep(Video).each { |each| HydrateVideoJob.perform_later(each.id) }
      when AnalysisRun::Step::Optimize
        version = media_file.optimized_version || OptimizedVersion.create!(media_file: media_file, household_id: media_file.household_id)
        version.requeue!(origin: OptimizedVersion::Origin::Manual)
      else T.absurd(step)
      end
    end
  end
end

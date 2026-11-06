# typed: strict
# frozen_string_literal: true

module Artworks
  # A picture for something no provider pictured (PROPOSAL §5.1): a frame
  # from a fifth of the way in — past cold opens and title cards, before the
  # credits — so an unmatched home recording still has a face in the grid.
  class FrameGrab
    extend T::Sig

    POSITION = 0.2

    sig { params(playable: T.any(Movie, Episode, Extra, Video, Clip)).void }
    def initialize(playable)
      @playable = playable
    end

    sig { void }
    def call
      return if pictured?

      file = @playable.media_files.playable.order(size: :desc).first
      return if file.nil?

      artwork = Artwork.find_or_initialize_by(owner: @playable, kind: Artwork::Kind::Thumb.serialize)
      same_file = artwork.source_enum == Artwork::Source::Frame && artwork.source_ref == file.id
      return if same_file && (artwork.ready? || artwork.given_up?)

      grab(artwork, file, same_file)
    end

    private

    # A frame that can't be grabbed (a timeout on a slow share, a file ffmpeg
    # can't decode) fails the file's Artwork step and the row, not the job.
    sig { params(artwork: Artwork, file: MediaFile, same_file: T::Boolean).void }
    def grab(artwork, file, same_file)
      AnalysisRun.track(file, AnalysisRun::Step::Artwork, tool_version: ToolRunner.version("ffmpeg")) do
        artwork.assign_attributes(source: Artwork::Source::Frame.serialize, source_ref: file.id)
        artwork.consecutive_failures = 0 unless same_file
        artwork.save!
        # Always a seek, so the video is decoded once however many sizes follow.
        seek = file.duration_seconds.to_f.positive? ? file.duration_seconds.to_f * POSITION : 0.0
        Publish.call(artwork, source: file.path, seek_seconds: seek)
      end
    rescue Renderer::Error, ToolRunner::Error, SystemCallError => e
      artwork.record_failure!(e)
    end

    # A provider image of the kind a grid would show beats any frame.
    sig { returns(T::Boolean) }
    def pictured?
      # A video's own thumbnail (beside it on disk, or YouTube's) beats a frame.
      return true if @playable.is_a?(Video) && Artwork.ready.exists?(owner: @playable, kind: Artwork::Kind::Thumb.serialize,
        source: [ Artwork::Source::Local.serialize, Artwork::Source::Youtube.serialize ])

      kinds = case @playable
      when Movie then [ Artwork::Kind::Poster, Artwork::Kind::Backdrop ]
      when Episode then [ Artwork::Kind::Still ]
      else []
      end
      Artwork.ready.exists?(owner: @playable, kind: kinds.map(&:serialize))
    end
  end
end

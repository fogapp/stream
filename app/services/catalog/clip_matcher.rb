# typed: strict
# frozen_string_literal: true

module Catalog
  # Files a probed home video as a clip (PROPOSAL §5.4), placed in time by
  # the best clock it has: what the camera wrote into the file, then a
  # camera-style name, then the file's own date. Immich's sync, when set up,
  # knows better and overrides.
  class ClipMatcher
    extend T::Sig

    # Tags cameras and phones write the moment of capture into.
    CREATION_TAGS = T.let(%w[com.apple.quicktime.creationdate creation_time date].freeze, T::Array[String])

    sig { params(file: MediaFile, library: Library, parsed: Media::NameParser::Parsed).void }
    def initialize(file, library, parsed)
      @file = file
      @library = library
      @parsed = parsed
    end

    sig { void }
    def call
      clip = Edition.find_by(media_file: @file, playable_type: "Clip")&.playable
      clip = nil unless clip.is_a?(Clip)
      captured, source = capture_time
      floating = source == Clip::CapturedSource::Filename
      clip ||= Clip.new(household_id: @file.household_id, library: @library, title: @parsed.title, captured_at: captured,
        captured_source: source.serialize, captured_floating: floating)
      unless clip.captured_source_enum == Clip::CapturedSource::Immich || clip.locked?("captured_at")
        clip.assign_attributes(captured_at: captured, captured_source: source.serialize, captured_floating: floating)
      end
      clip.save!
      Edition.where(media_file: @file).where.not(playable: clip).delete_all
      Edition.find_or_create_by!(media_file: @file, playable: clip)
      SyncArtworkJob.perform_later("Clip", clip.id)
    end

    private

    sig { returns([ Time, Clip::CapturedSource ]) }
    def capture_time
      tags = @file.probe.dig("format", "tags")
      if tags.is_a?(Hash)
        lowered = tags.transform_keys(&:downcase)
        CREATION_TAGS.each do |key|
          time = parse_time(lowered[key])
          return [ time, Clip::CapturedSource::Metadata ] if time
        end
      end
      wall = @parsed.wall_clock
      return [ wall, Clip::CapturedSource::Filename ] if wall

      date = @parsed.air_date
      return [ Time.utc(date.year, date.month, date.day, 12), Clip::CapturedSource::Filename ] if date

      [ @file.mtime.to_time, Clip::CapturedSource::FileDate ]
    end

    # A real moment, not a camera's unset clock (1970, 1904) or the future.
    sig { params(value: T.untyped).returns(T.nilable(Time)) }
    def parse_time(value)
      time = Time.zone.parse(value.to_s)&.to_time
      time if time && time.year > 1990 && time < 1.day.from_now
    rescue ArgumentError
      nil
    end
  end
end

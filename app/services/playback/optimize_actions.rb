# typed: strict
# frozen_string_literal: true

module Playback
  # What an admin can do to optimized versions from the Playback page, to
  # one file or many at once. Each file either changes or says why not, and
  # the page reports the tally ("Queued 14 · 3 already ready").
  class OptimizeActions
    extend T::Sig

    class Action < T::Enum
      include ApplicationEnum
      enums do
        # Queue one, ahead of the automatic ones; with now, outside quiet hours too.
        Optimize = new("optimize")
        # Next in line, ahead of everything else queued.
        Prioritize = new("prioritize")
        # Never make one: stops an encode, deletes one made, keeps the hourly pass away.
        Skip = new("skip")
        # Let the hourly pass consider the file again.
        Unskip = new("unskip")
        # Make a ready one again, say after the height setting changed.
        Reencode = new("reencode")
        Retry = new("retry")
        # Gone, file and all; the hourly pass may queue it again.
        Delete = new("delete")
      end
    end

    # As many files as one request may touch.
    LIMIT = 500

    class Result < T::Struct
      const :changed, Integer
      # Why the rest didn't, and how many each.
      const :unchanged, T::Hash[String, Integer]
    end

    # What someone did, for the activity log: "… said not to optimize 3 files".
    sig { params(action: Action, count: Integer, now: T::Boolean).returns(String) }
    def self.summary(action, count, now:)
      files = count == 1 ? "1 file" : "#{count} files"
      versions = count == 1 ? "1 optimized version" : "#{count} optimized versions"
      words =
        case action
        when Action::Optimize then "asked for an optimized version of #{files}"
        when Action::Prioritize then "moved #{files} to the front of the optimize queue"
        when Action::Skip then "said not to optimize #{files}"
        when Action::Unskip then "let #{files} be optimized again"
        when Action::Reencode then "asked for #{versions} to be made again"
        when Action::Retry then "retried #{versions}"
        when Action::Delete then "deleted #{versions}"
        else T.absurd(action)
        end
      now && [ Action::Optimize, Action::Prioritize, Action::Reencode, Action::Retry ].include?(action) ? "#{words}, now" : words
    end

    sig { params(action: Action, media_file_ids: T::Array[String], now: T::Boolean, household: Household).void }
    def initialize(action:, media_file_ids:, now:, household:)
      @action = action
      @media_file_ids = T.let(media_file_ids.uniq.first(LIMIT), T::Array[String])
      @now = now
      @household = household
    end

    sig { returns(Result) }
    def call
      changed = 0
      unchanged = Hash.new(0)
      files = MediaFile.where(id: @media_file_ids).includes(:optimized_version).to_a
      missing = @media_file_ids.size - files.size
      unchanged["not found"] = missing if missing.positive?
      files.each do |file|
        refusal = apply(file, file.optimized_version)
        refusal ? unchanged[refusal] += 1 : changed += 1
      end
      Result.new(changed: changed, unchanged: unchanged)
    end

    private

    # Does it to one file; the reason it didn't when it didn't.
    sig { params(file: MediaFile, version: T.nilable(OptimizedVersion)).returns(T.nilable(String)) }
    def apply(file, version)
      state = version&.state_enum
      case @action
      when Action::Optimize
        return "can't be read yet" unless file.state_enum == MediaFile::State::Probed
        return "already encoding" if state == OptimizedVersion::State::Encoding
        return "already made" if state == OptimizedVersion::State::Ready
        return "already queued" if state == OptimizedVersion::State::Queued && version&.origin_enum == OptimizedVersion::Origin::Manual &&
                                   (version&.run_now || !@now)

        version ||= OptimizedVersion.create!(household_id: @household.id, media_file: file)
        version.requeue!(origin: OptimizedVersion::Origin::Manual, run_now: @now)
      when Action::Prioritize
        return "not queued" unless version && state == OptimizedVersion::State::Queued

        version.prioritize!
        version.update!(run_now: true) if @now
      when Action::Skip
        return "already not optimizing" if state == OptimizedVersion::State::Skipped

        version ||= OptimizedVersion.create!(household_id: @household.id, media_file: file, origin: OptimizedVersion::Origin::Manual.serialize)
        version.skip!
      when Action::Unskip
        return "not skipped" unless version && state == OptimizedVersion::State::Skipped

        version.destroy!
      when Action::Reencode
        return "not made yet" unless version && state == OptimizedVersion::State::Ready

        FileUtils.rm_f(version.path)
        version.update!(size: nil, finished_at: nil)
        version.requeue!(origin: OptimizedVersion::Origin::Manual, run_now: @now)
      when Action::Retry
        return "hasn't failed" unless version && state == OptimizedVersion::State::Failed

        version.requeue!(run_now: @now)
      when Action::Delete
        return "nothing to delete" unless version

        version.destroy!
      else T.absurd(@action)
      end
      nil
    end
  end
end

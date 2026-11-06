# typed: strict
# frozen_string_literal: true

module Playback
  # Puts what a run made where web serves it from (PROPOSAL §6.3). A run
  # writes into a directory of its own, one fragment per keyframe; each
  # fragment it finishes is read (Fragment) and filed under the GOP of the
  # plan whose stretch of the film it falls in — ffmpeg decides where a
  # seek lands and where it cuts, and the plan is only what the file's
  # index said. A GOP is its planned
  # keyframe's fragment and every fragment after it until the next planned
  # keyframe: a keyframe the index didn't list (Matroska Cues list as few
  # as one in three; scene cuts) is part of the GOP it falls in, not an
  # error. Until it is whole, a GOP is assembled in the run's directory, so
  # web never sees half of one.
  #
  # A GOP already published is left as it is: whichever run made it first,
  # its address serves the same bytes for as long as the session lives,
  # which is what lets a browser keep it (MediaController). The init
  # segment is published once, the same way.
  #
  # What can't be reconciled is refused, and says so — the run it came from
  # is stopped with its reason recorded (Supervisor), never served as
  # something it isn't: a fragment before the plan's first GOP, a run going
  # backwards, or a planned keyframe the file doesn't have.
  class Publisher
    extend T::Sig

    class Mismatch < StandardError; end

    # How far from its GOP's planned start a copied fragment's first frame
    # may be: the keyframe index is in whole milliseconds. Past it, a
    # fragment is a keyframe the index didn't list, inside the GOP. Also
    # how near the next planned keyframe a GOP's fragments must reach to be
    # whole.
    COPY_SLACK_MS = 50

    # How far before it, too. An open GOP's keyframe is shown after frames
    # that follow it in decode order, and a run passing through one
    # (-copyts, frag_discont) stamps it as if it were shown only as late as
    # the stream's first keyframe: early by the difference (167 ms on an
    # x265 WEBRip). No reordering holds a frame back longer than sixteen
    # frames (two thirds of a second at 24 fps), and the fragment must
    # still be nearer this keyframe than the one before (SegmentPlan).
    COPY_EARLY_MS = 750

    # How far before its slot a converted fragment's first frame may be and
    # still start that slot. A forced keyframe is the first frame ffmpeg
    # counts as in the slot, and it counts from the run's first frame: one
    # an input seek keeps for being on screen at the seek, just before it
    # (an XviD AVI's, by 10 ms). Every keyframe of that run is early by as
    # much, which a few milliseconds of rounding didn't allow for — and
    # taken as late in the slot before, it left the slot it started
    # missing. A frame at 4 fps; a keyframe the encoder adds of its own,
    # further in, still belongs to the slot it's in.
    GRID_EARLY_MS = 250

    sig { params(session_id: String, variant: Integer, plan: SegmentPlan).void }
    def initialize(session_id:, variant:, plan:)
      @session_id = session_id
      @variant = variant
      @plan = plan
      @tracks = T.let(nil, T.nilable(T::Array[Fragment::Track]))
    end

    # The run's init segment: published if the session has none yet, and
    # otherwise checked against the one it has, since every fragment is
    # played with that one.
    sig { params(init: Pathname).void }
    def init(init)
      tracks = Fragment.tracks(init)
      target = Cache.init(@session_id, @variant)
      if target.file?
        published = Fragment.tracks(target)
        unless timing(published) == timing(tracks)
          raise Mismatch, "this run's init segment times its tracks differently from the one already published"
        end
        # Another encoder, or the same one set differently (a remote node's
        # run carried on here): its fragments can't be decoded with the
        # published init.
        unless configs(published) == configs(tracks)
          raise Mismatch, "this run's picture is encoded differently from the one already published"
        end
      else
        FileUtils.mkdir_p(target.dirname)
        temporary = target.sub_ext(".#{SecureRandom.hex(4)}.tmp")
        begin
          FileUtils.cp(init, temporary)
          File.rename(temporary, target)
        ensure
          FileUtils.rm_f(temporary)
        end
      end
      @tracks = tracks
    end

    sig { returns(T::Boolean) }
    def init? = !@tracks.nil?

    # Files a finished fragment under the GOP it belongs to, and publishes
    # that GOP once it's whole. Says which GOP was published, if one was.
    sig { params(staged: Pathname).returns(T.nilable(Integer)) }
    def fragment(staged)
      tracks = @tracks
      raise Mismatch, "a fragment arrived before its init segment" if tracks.nil?

      span = Fragment.video_span_ms(staged, tracks)
      if span.nil?
        # Sound alone is a fragment; nothing at all isn't one.
        raise Mismatch, "#{staged.basename} has no picture and no sound" if Fragment.runs(staged).none? { |run| run.samples.positive? }

        return soundtrack(staged)
      end

      start, finish = span
      name = "#{staged.basename} (at #{start / 1000.0} s)"
      begins = if @plan.grid?
        @plan.gop_starting_at(start, SegmentPlan::ROUNDING_MS, early_ms: GRID_EARLY_MS) || @plan.gop_starting_at(start, @plan.target_ms)
      else @plan.gop_starting_at(start, COPY_SLACK_MS, early_ms: COPY_EARLY_MS)
      end
      within = begins || @plan.gop_containing(start)
      raise Mismatch, "#{name} is before the plan's first GOP" if within.nil?

      held = Held.read(staged.dirname)
      # A run's seek can land a keyframe past the one asked for, when the
      # index left out one just after it: that GOP, a few frames short.
      begins = within if held.nil? && begins.nil? && start - @plan.gop_start_ms(within) <= SEEK_LANDING_MS

      published = T.let(nil, T.nilable(Integer))
      if held&.gop == within
        held = T.must(held)
        case held.kind
        when Held::OPEN then held.append(staged)
        when Held::SKIP then FileUtils.rm_f(staged)
        else
          # Past the film's end as the plan has it (a converted run's last
          # frame stamped at the end itself): nothing anyone plays to.
          raise Mismatch, "#{name} is in GOP #{within}, which this run had already finished" unless past_the_end?(start)

          FileUtils.rm_f(staged)
        end
      else
        published = settle(held, within, begins.nil?, name) if held
        held = hold(staged, within, headless: begins.nil?)
      end
      # Whole once it reaches the next planned keyframe: published now
      # rather than when the next fragment comes.
      published = publish(held) || published if held.kind == Held::OPEN && finish && finish >= @plan.gop_end_ms(held.gop) - COPY_SLACK_MS
      published
    rescue Fragment::Unreadable => e
      raise Mismatch, "#{staged.basename} couldn't be read: #{e.message}"
    end

    sig { params(start: Integer).returns(T::Boolean) }
    def past_the_end?(start) = start >= @plan.gop_end_ms(@plan.gop_count - 1) - COPY_SLACK_MS

    # A fragment of sound alone: the muxer cuts one from what arrives before
    # a run's first picture (TS and AVI sound often starts first). Part of
    # the GOP being made if there is one; before the first, nothing a
    # player is short of — dropped, never the end of the stream.
    sig { params(staged: Pathname).returns(T.nilable(Integer)) }
    def soundtrack(staged)
      held = Held.read(staged.dirname)
      held && held.kind == Held::OPEN ? held.append(staged) : FileUtils.rm_f(staged)
      nil
    end

    # A run is over: the GOP it was making is published if it was the
    # film's last, which nothing after it will close. Any other is
    # incomplete and goes with the run.
    sig { params(staging: Pathname).returns(T.nilable(Integer)) }
    def finish(staging)
      held = Held.read(staging)
      return nil if held.nil? || held.kind != Held::OPEN || held.gop != @plan.gop_count - 1

      publish(held)
    end

    # Where a run is in the plan, kept in the run's own directory (which a
    # remote run's uploads share, one Publisher per upload): the GOP it is
    # making (open-<gop>.m4s, its fragments so far), one it can't make
    # (skip-<gop>: published already, or the run began partway into it), or
    # the last it finished (done-<gop>). One at a time.
    class Held < T::Struct
      extend T::Sig

      OPEN = "open"
      SKIP = "skip"
      DONE = "done"
      PATTERN = /\A(open|skip|done)-(\d+)(?:\.m4s)?\z/

      const :kind, String
      const :gop, Integer
      const :path, Pathname

      sig { params(directory: Pathname).returns(T.nilable(Held)) }
      def self.read(directory)
        return nil unless directory.directory?

        Dir.each_child(directory) do |child|
          match = PATTERN.match(child)
          return new(kind: T.must(match[1]), gop: match[2].to_i, path: directory.join(child)) if match
        end
        nil
      end

      sig { params(directory: Pathname, kind: String, gop: Integer).returns(Held) }
      def self.mark(directory, kind, gop)
        path = directory.join("#{kind}-#{gop}")
        FileUtils.touch(path)
        new(kind: kind, gop: gop, path: path)
      end

      sig { params(staged: Pathname).void }
      def append(staged)
        File.open(path, "ab") { |out| File.open(staged, "rb") { |source| IO.copy_stream(source, out) } }
        FileUtils.rm_f(staged)
      end
    end

    # How far past its GOP's keyframe a run's first fragment may start and
    # still be taken as that GOP: a seek aims a little past the keyframe
    # (FfmpegArgs.copy_seek), and lands on the last keyframe before where it
    # aims.
    SEEK_LANDING_MS = 250

    private

    # A fragment that starts another GOP. The one before it is whole and
    # published if it was being made; and a run's fragments follow on from
    # each other, so this one must start the GOP after it — anything else is
    # a run going backwards, or a planned keyframe the file doesn't have.
    sig { params(held: Held, within: Integer, headless: T::Boolean, name: String).returns(T.nilable(Integer)) }
    def settle(held, within, headless, name)
      published = held.kind == Held::OPEN ? publish(held) : nil
      FileUtils.rm_f(staging_marker(held))
      raise Mismatch, "#{name} is behind GOP #{held.gop}, which this run had reached" if within < held.gop

      missing = within > held.gop + 1 ? held.gop + 1 : (within if headless)
      if missing
        raise Mismatch, "#{name} follows GOP #{held.gop}, and the plan's GOP #{missing} " \
          "(#{@plan.gop_start_ms(missing) / 1000.0} s) isn't a keyframe of this file"
      end
      published
    end

    # Starts making the GOP a fragment begins, or skips it.
    sig { params(staged: Pathname, gop: Integer, headless: T::Boolean).returns(Held) }
    def hold(staged, gop, headless:)
      if headless || Cache.gop(@session_id, gop, @variant).file?
        FileUtils.rm_f(staged)
        return Held.mark(staged.dirname, Held::SKIP, gop)
      end

      path = staged.dirname.join("#{Held::OPEN}-#{gop}.m4s")
      File.rename(staged, path)
      Held.new(kind: Held::OPEN, gop: gop, path: path)
    end

    # A whole GOP, published unless another run published it first; the
    # run then remembers it finished it.
    sig { params(held: Held).returns(T.nilable(Integer)) }
    def publish(held)
      target = Cache.gop(@session_id, held.gop, @variant)
      if target.file?
        FileUtils.rm_f(held.path)
        published = nil
      else
        File.rename(held.path, target)
        published = held.gop
      end
      Held.mark(held.path.dirname, Held::DONE, held.gop)
      published
    end

    # What's left of a held GOP's mark once it's settled: a published GOP's
    # done-<gop>, or the mark itself.
    sig { params(held: Held).returns(Pathname) }
    def staging_marker(held) = held.kind == Held::OPEN ? held.path.dirname.join("#{Held::DONE}-#{held.gop}") : held.path

    # What placing a fragment depends on: each track's timescale, and where
    # the picture's time zero is.
    sig { params(tracks: T::Array[Fragment::Track]).returns(T::Array[T::Array[T.untyped]]) }
    def timing(tracks) = tracks.map { |track| [ track.id, track.video, track.timescale, track.video ? track.media_time : 0 ] }

    sig { params(tracks: T::Array[Fragment::Track]).returns(T::Array[T.nilable(String)]) }
    def configs(tracks) = tracks.map(&:config)
  end
end
